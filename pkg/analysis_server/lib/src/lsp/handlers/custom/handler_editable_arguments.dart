// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analysis_server/lsp_protocol/protocol.dart' hide Element;
import 'package:analysis_server/src/lsp/constants.dart';
import 'package:analysis_server/src/lsp/error_or.dart';
import 'package:analysis_server/src/lsp/handlers/handlers.dart';
import 'package:analysis_server/src/lsp/mapping.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element2.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/lint/linter.dart';
import 'package:analyzer/src/utilities/extensions/ast.dart';
import 'package:analyzer/src/utilities/extensions/flutter.dart';

/// Information about the arguments and parameters for an invocation.
typedef _InvocationInfo = (List<FormalParameterElement>?, ArgumentList?);

/// Information about the values for a parameter/argument.
typedef _Values =
    ({bool isDefault, DartObject? parameterValue, DartObject? argumentValue});

class EditableArgumentsHandler
    extends
        SharedMessageHandler<TextDocumentPositionParams, EditableArguments?> {
  EditableArgumentsHandler(super.server);

  @override
  Method get handlesMessage => CustomMethods.dartTextDocumentEditableArguments;

  @override
  LspJsonHandler<TextDocumentPositionParams> get jsonHandler =>
      TextDocumentPositionParams.jsonHandler;

  @override
  bool get requiresTrustedCaller => false;

  @override
  Future<ErrorOr<EditableArguments?>> handle(
    TextDocumentPositionParams params,
    MessageInfo message,
    CancellationToken token,
  ) async {
    var textDocument = params.textDocument;
    var position = params.position;

    var filePath = pathOfDoc(textDocument);
    var result = await filePath.mapResult(requireResolvedUnit);
    var docIdentifier = filePath.mapResultSync(
      (filePath) => success(extractDocumentVersion(textDocument, filePath)),
    );
    var offset = result.mapResultSync(
      (result) => toOffset(result.lineInfo, position),
    );

    return await (filePath, result, docIdentifier, offset).mapResults((
      filePath,
      result,
      docIdentifier,
      offset,
    ) async {
      // Check for document changes or cancellation after the awaits above.
      if (fileHasBeenModified(filePath, docIdentifier.version)) {
        return fileModifiedError;
      } else if (token.isCancellationRequested) {
        return cancelled();
      }

      // Compute the editable arguments for an invocation at `offset`.
      var editableArguments = _getEditableArguments(
        result,
        textDocument,
        offset,
      );

      return success(editableArguments);
    });
  }

  /// Computes the [EditableArguments] for an invocation at `offset`.
  ///
  /// Returns `null` if there is no suitable invocation at this location.
  EditableArguments? _getEditableArguments(
    ResolvedUnitResult result,
    TextDocumentIdentifier textDocument,
    int offset,
  ) {
    var (parameters, argumentList) = _getInvocationInfo(result, offset);
    if (parameters == null || argumentList == null) {
      return null;
    }

    var textDocument = server.getVersionedDocumentIdentifier(result.path);

    // Build a map of the parameters that have matching arguments.
    var parametersWithArguments = {
      for (var argument in argumentList.arguments)
        argument.correspondingParameter: argument,
    };

    var editableArguments = [
      // First include the arguments in the order they were specified.
      for (var MapEntry(key: parameter, value: argument)
          in parametersWithArguments.entries)
        if (parameter != null) _toEditableArgument(parameter, argument),
      // Then the remaining parameters.
      for (var parameter in parameters.where(
        (p) => !parametersWithArguments.containsKey(p),
      ))
        _toEditableArgument(parameter, null),
    ];

    return EditableArguments(
      textDocument: textDocument,
      arguments: editableArguments.nonNulls.toList(),
    );
  }

  /// Gets the argument list at [offset] that can be edited.
  _InvocationInfo _getInvocationInfo(ResolvedUnitResult result, int offset) {
    var node = result.unit.nodeCovering(offset: offset);
    // Walk up to find an invocation that is widget creation.
    var invocation = node?.thisOrAncestorMatching((node) {
      return switch (node) {
        InstanceCreationExpression() => node.isWidgetCreation,
        InvocationExpressionImpl() => node.isWidgetFactory,
        _ => false,
      };
    });

    // Return the related argument list.
    return switch (invocation) {
      InstanceCreationExpression() => (
        invocation.constructorName.element?.formalParameters,
        invocation.argumentList,
      ),
      MethodInvocation(
        methodName: Identifier(element: ExecutableElement2 element),
      ) =>
        (element.formalParameters, invocation.argumentList),
      _ => (null, null),
    };
  }

  /// Computes the values for a parameter and argument and returns them along
  /// with a flag indicating if the default parameter value is being used.
  _Values _getValues(
    FormalParameterElement parameter,
    Expression? argumentExpression,
  ) {
    var parameterValue = parameter.computeConstantValue();
    var argumentValue = argumentExpression?.computeConstantValue().value;

    var isDefault =
        argumentValue == null ||
        ((parameterValue?.hasKnownValue ?? false) &&
            (argumentValue.hasKnownValue) &&
            parameterValue == argumentValue);

    return (
      isDefault: isDefault,
      parameterValue: parameterValue,
      argumentValue: argumentValue,
    );
  }

  /// Converts a [parameter]/[argument] pair into an [EditableArgument] if it
  /// is an argument that can be edited.
  EditableArgument? _toEditableArgument(
    FormalParameterElement parameter,
    Expression? argument,
  ) {
    var valueExpression =
        argument is NamedExpression ? argument.expression : argument;

    // Lazily compute the values if we will use this parameter/argument.
    late var values = _getValues(parameter, valueExpression);

    String? type;
    Object? value;
    List<String>? options;

    if (parameter.type.isDartCoreDouble) {
      type = 'double';
      value =
          (values.argumentValue ?? values.parameterValue)?.toDoubleValue() ??
          (values.argumentValue ?? values.parameterValue)?.toIntValue();
    } else if (parameter.type.isDartCoreInt) {
      type = 'int';
      value = (values.argumentValue ?? values.parameterValue)?.toIntValue();
    } else if (parameter.type.isDartCoreBool) {
      type = 'bool';
      value = (values.argumentValue ?? values.parameterValue)?.toBoolValue();
    } else if (parameter.type.isDartCoreString) {
      type = 'string';
      value = (values.argumentValue ?? values.parameterValue)?.toStringValue();
    } else {
      // TODO(dantup): Enums.

      // TODO(dantup): Determine which parameters we don't include (such as
      //  Widgets) and which we include just without values.
      return null;
    }

    return EditableArgument(
      name: parameter.displayName,
      type: type,
      value: value,
      displayValue:
          valueExpression is! Literal ? valueExpression?.toSource() : null,
      options: options,
      isDefault: values.isDefault,
      hasArgument: valueExpression != null,
      isRequired: parameter.isRequired,
      isNullable:
          parameter.type.nullabilitySuffix == NullabilitySuffix.question,
    );
  }
}

extension on InvocationExpressionImpl {
  /// Whether this is an invocation for an extension method that has the
  /// `@widgetFactory` annotation.
  bool get isWidgetFactory {
    // Only consider functions that return widgets.
    if (!staticType.isWidgetType) {
      return false;
    }

    // We only support @widgetFactory on extension methods.
    var element = switch (function) {
      Identifier(:var element)
          when element?.enclosingElement2 is ExtensionElement2 =>
        element,
      _ => null,
    };

    return switch (element) {
      FragmentedAnnotatableElementMixin(:var metadata2) =>
        metadata2.hasWidgetFactory,
      _ => false,
    };
  }
}
