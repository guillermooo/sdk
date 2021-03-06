// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * Code for displaying the API as HTML.  This is used both for generating a
 * full description of the API as a web page, and for generating doc comments
 * in generated code.
 */
library to.html;

import 'dart:convert';

import 'package:html/dom.dart' as dom;

import 'api.dart';
import 'codegen_tools.dart';
import 'from_html.dart';
import 'html_tools.dart';

/**
 * Embedded stylesheet
 */
final String stylesheet = '''
body {
  font-family: sans-serif, serif;
  padding-left: 5%;
  padding-right: 5%;
}
h1 {
  text-align: center;
}
h2.domain {
  border-bottom: 3px solid rgb(160, 160, 160);
}
pre {
  margin: 0px;
}
div.box {
  border: 1px solid rgb(0, 0, 0);
  background-color: rgb(207, 226, 243);
  padding: 0.5em;
}
div.hangingIndent {
  padding-left: 3em;
  text-indent: -3em;
}
dt {
  margin-top: 1em;
  margin-bottom: 1em;
}
dt.notification {
  font-weight: bold;
}
dt.refactoring {
  font-weight: bold;
}
dt.request {
  font-weight: bold;
}
dt.typeDefinition {
  font-weight: bold;
}

*/
* Styles for index
*/

.subindex {
}

.subindex ul {
  padding-left: 0px;
  margin-left: 0px;

  -webkit-margin-before: 0px;
  -webkit-margin-start: 0px;
  -webkit-padding-start: 0px;

  list-style-type: none;
}
'''.trim();

final GeneratedFile target = new GeneratedFile('../../doc/api.html', () {
  ToHtmlVisitor visitor = new ToHtmlVisitor(readApi());
  dom.Document document = new dom.Document();
  for (dom.Node node in visitor.collectHtml(visitor.visitApi)) {
    document.append(node);
  }
  return document.outerHtml;
});

/**
 * Translate spec_input.html into api.html.
 */
main() {
  target.generate();
}

/**
 * Visitor that records the mapping from HTML elements to various kinds of API
 * nodes.
 */
class ApiMappings extends HierarchicalApiVisitor {
  Map<dom.Element, Domain> domains = <dom.Element, Domain>{};

  ApiMappings(Api api) : super(api);

  @override
  void visitDomain(Domain domain) {
    domains[domain.html] = domain;
  }
}

/**
 * Helper methods for creating HTML elements.
 */
abstract class HtmlMixin {
  void anchor(String id, void callback()) {
    element('a', {'name': id}, callback);
  }

  void b(void callback()) => element('b', {}, callback);
  void body(void callback()) => element('body', {}, callback);
  void box(void callback()) {
    element('div', {'class': 'box'}, callback);
  }
  void br() => element('br', {});
  void dd(void callback()) => element('dd', {}, callback);
  void dl(void callback()) => element('dl', {}, callback);
  void dt(String cls, void callback()) =>
      element('dt', {'class': cls}, callback);
  void element(String name, Map<dynamic, String> attributes, [void callback()]);
  void gray(void callback()) =>
      element('span', {'style': 'color:#999999'}, callback);
  void h1(void callback()) => element('h1', {}, callback);
  void h2(String cls, void callback()) {
    if (cls == null) {
      return element('h2', {}, callback);
    }
    return element('h2', {'class': cls}, callback);
  }
  void h3(void callback()) => element('h3', {}, callback);
  void h4(void callback()) => element('h4', {}, callback);
  void h5(void callback()) => element('h5', {}, callback);
  void hangingIndent(void callback()) =>
      element('div', {'class': 'hangingIndent'}, callback);
  void head(void callback()) => element('head', {}, callback);
  void html(void callback()) => element('html', {}, callback);
  void i(void callback()) => element('i', {}, callback);
  void link(String id, void callback()) {
    element('a', {'href': '#$id'}, callback);
  }
  void p(void callback()) => element('p', {}, callback);
  void pre(void callback()) => element('pre', {}, callback);
  void title(void callback()) => element('title', {}, callback);
  void tt(void callback()) => element('tt', {}, callback);
}

/**
 * Visitor that generates HTML documentation of the API.
 */
class ToHtmlVisitor extends HierarchicalApiVisitor
    with HtmlMixin, HtmlGenerator {
  /**
   * Set of types defined in the API.
   */
  Set<String> definedTypes = new Set<String>();

  /**
   * Mappings from HTML elements to API nodes.
   */
  ApiMappings apiMappings;

  ToHtmlVisitor(Api api)
      : super(api),
        apiMappings = new ApiMappings(api) {
    apiMappings.visitApi();
  }

  /**
   * Describe the payload of request, response, notification, refactoring
   * feedback, or refactoring options.
   *
   * If [force] is true, then a section is inserted even if the payload is
   * null.
   */
  void describePayload(TypeObject subType, String name, {bool force: false}) {
    if (force || subType != null) {
      h4(() {
        write(name);
      });
      if (subType == null) {
        p(() {
          write('none');
        });
      } else {
        visitTypeDecl(subType);
      }
    }
  }

  void javadocParams(TypeObject typeObject) {
    if (typeObject != null) {
      for (TypeObjectField field in typeObject.fields) {
        hangingIndent(() {
          write('@param ${field.name} ');
          translateHtml(field.html, squashParagraphs: true);
        });
      }
    }
  }

  /**
   * Generate a description of [type] using [TypeVisitor].
   *
   * If [shortDesc] is non-null, the output is prefixed with this string
   * and a colon.
   *
   * If [typeForBolding] is supplied, then fields in this type are shown in
   * boldface.
   */
  void showType(String shortDesc, TypeDecl type, [TypeObject typeForBolding]) {
    Set<String> fieldsToBold = new Set<String>();
    if (typeForBolding != null) {
      for (TypeObjectField field in typeForBolding.fields) {
        fieldsToBold.add(field.name);
      }
    }
    pre(() {
      if (shortDesc != null) {
        write('$shortDesc: ');
      }
      TypeVisitor typeVisitor =
          new TypeVisitor(api, fieldsToBold: fieldsToBold);
      addAll(typeVisitor.collectHtml(() {
        typeVisitor.visitTypeDecl(type);
      }));
    });
  }

  /**
   * Copy the contents of the given HTML element, translating the special
   * elements that define the API appropriately.
   */
  void translateHtml(dom.Element html, {bool squashParagraphs: false}) {
    for (dom.Node node in html.nodes) {
      if (node is dom.Element) {
        if (squashParagraphs && node.localName == 'p') {
          translateHtml(node, squashParagraphs: squashParagraphs);
          continue;
        }
        switch (node.localName) {
          case 'domain':
            visitDomain(apiMappings.domains[node]);
            break;
          case 'head':
            head(() {
              translateHtml(node, squashParagraphs: squashParagraphs);
              element('style', {}, () {
                writeln(stylesheet);
              });
            });
            break;
          case 'refactorings':
            visitRefactorings(api.refactorings);
            break;
          case 'types':
            visitTypes(api.types);
            break;
          case 'version':
            translateHtml(node, squashParagraphs: squashParagraphs);
            break;
          case 'index':
            generateIndex();
            break;
          default:
            if (!specialElements.contains(node.localName)) {
              element(node.localName, node.attributes, () {
                translateHtml(node, squashParagraphs: squashParagraphs);
              });
            }
        }
      } else if (node is dom.Text) {
        String text = node.text;
        write(text);
      }
    }
  }

  @override
  void visitApi() {
    definedTypes = api.types.keys.toSet();

    html(() {
      translateHtml(api.html);
    });
  }

  @override
  void visitDomain(Domain domain) {
    h2('domain', () {
      anchor('domain_${domain.name}', () {
        write('Domain: ${domain.name}');
      });
    });
    translateHtml(domain.html);
    if (domain.requests.isNotEmpty) {
      h3(() {
        write('Requests');
      });
      dl(() {
        domain.requests.forEach(visitRequest);
      });
    }
    if (domain.notifications.isNotEmpty) {
      h3(() {
        write('Notifications');
      });
      dl(() {
        domain.notifications.forEach(visitNotification);
      });
    }
  }

  @override
  void visitNotification(Notification notification) {
    dt('notification', () {
      anchor('notification_${notification.longEvent}', () {
        write(notification.longEvent);
      });
      write(' (');
      link('notification_${notification.longEvent}', () {
        write('#');
      });
      write(')');
    });
    dd(() {
      box(() {
        showType(
            'notification', notification.notificationType, notification.params);
      });
      translateHtml(notification.html);
      describePayload(notification.params, 'Parameters');
    });
  }

  @override visitRefactoring(Refactoring refactoring) {
    dt('refactoring', () {
      write(refactoring.kind);
    });
    dd(() {
      translateHtml(refactoring.html);
      describePayload(refactoring.feedback, 'Feedback', force: true);
      describePayload(refactoring.options, 'Options', force: true);
    });
  }

  @override
  void visitRefactorings(Refactorings refactorings) {
    translateHtml(refactorings.html);
    dl(() {
      super.visitRefactorings(refactorings);
    });
  }

  @override
  void visitRequest(Request request) {
    dt('request', () {
      anchor('request_${request.longMethod}', () {
        write(request.longMethod);
      });
      write(' (');
      link('request_${request.longMethod}', () {
        write('#');
      });
      write(')');
    });
    dd(() {
      box(() {
        showType('request', request.requestType, request.params);
        br();
        showType('response', request.responseType, request.result);
      });
      translateHtml(request.html);
      describePayload(request.params, 'Parameters');
      describePayload(request.result, 'Returns');
    });
  }

  @override
  void visitTypeDefinition(TypeDefinition typeDefinition) {
    dt('typeDefinition', () {
      anchor('type_${typeDefinition.name}', () {
        write('${typeDefinition.name}: ');
        TypeVisitor typeVisitor = new TypeVisitor(api, short: true);
        addAll(typeVisitor.collectHtml(() {
          typeVisitor.visitTypeDecl(typeDefinition.type);
        }));
      });
    });
    dd(() {
      translateHtml(typeDefinition.html);
      visitTypeDecl(typeDefinition.type);
    });
  }

  @override
  void visitTypeEnum(TypeEnum typeEnum) {
    dl(() {
      super.visitTypeEnum(typeEnum);
    });
  }

  @override
  void visitTypeEnumValue(TypeEnumValue typeEnumValue) {
    bool isDocumented = false;
    for (dom.Node node in typeEnumValue.html.nodes) {
      if ((node is dom.Element && node.localName != 'code') ||
          (node is dom.Text && node.text.trim().isNotEmpty)) {
        isDocumented = true;
        break;
      }
    }
    dt('value', () {
      write(typeEnumValue.value);
    });
    if (isDocumented) {
      dd(() {
        translateHtml(typeEnumValue.html);
      });
    }
  }

  @override
  void visitTypeList(TypeList typeList) {
    visitTypeDecl(typeList.itemType);
  }

  @override
  void visitTypeMap(TypeMap typeMap) {
    visitTypeDecl(typeMap.valueType);
  }

  @override
  void visitTypeObject(TypeObject typeObject) {
    dl(() {
      super.visitTypeObject(typeObject);
    });
  }

  @override
  void visitTypeObjectField(TypeObjectField typeObjectField) {
    dt('field', () {
      b(() {
        i(() {
          write(typeObjectField.name);
          if (typeObjectField.value != null) {
            write(' = ${JSON.encode(typeObjectField.value)}');
          } else {
            write(' ( ');
            if (typeObjectField.optional) {
              gray(() {
                write('optional');
              });
              write(' ');
            }
            TypeVisitor typeVisitor = new TypeVisitor(api, short: true);
            addAll(typeVisitor.collectHtml(() {
              typeVisitor.visitTypeDecl(typeObjectField.type);
            }));
            write(' )');
          }
        });
      });
    });
    dd(() {
      translateHtml(typeObjectField.html);
    });
  }

  @override
  void visitTypeReference(TypeReference typeReference) {}

  @override
  void visitTypes(Types types) {
    translateHtml(types.html);
    dl(() {
      super.visitTypes(types);
    });
  }

  void generateIndex() {
    h3(() => write('Domains'));
    for (var domain in api.domains) {
      if (domain.requests.length == 0 && domain.notifications == 0) continue;
      generateDomainIndex(domain);
    }

    generateTypesIndex(definedTypes);
    generateRefactoringsIndex(api.refactorings);
  }

  void generateDomainIndex(Domain domain) {
    h4(() {
      write(domain.name);
      write(' (');
      link('domain_${domain.name}', () => write('\u2191'));
      write(')');
    });
    if (domain.requests.length > 0) {
      element('div', {'class': 'subindex'}, () {
        generateRequestsIndex(domain.requests);
        if (domain.notifications.length > 0) {
          generateNotificationsIndex(domain.notifications);
        }
      });
    } else if (domain.notifications.length > 0) {
      element('div', {'class': 'subindex'}, () {
        generateNotificationsIndex(domain.notifications);
      });
    }
  }

  void generateRequestsIndex(Iterable<Request> requests) {
    h5(() => write("Requests"));
    element('ul', {}, () {
      for (var request in requests) {
        element('li', {}, () => link('request_${request.longMethod}', () =>
          write(request.method)));
      }
    });
  }

  void generateNotificationsIndex(Iterable<Notification> notifications) {
    h5(() => write("Notifications"));
    element('div', {'class': 'subindex'}, () {
      element('ul', {}, () {
        for (var notification in notifications) {
          element('li', {}, () => link('notification_${notification.longEvent}',
            () => write(notification.event)));
        }
      });
    });
  }

  void generateTypesIndex(Set<String> types) {
    h3(() {
      write("Types");
      write(' (');
      link('types', () => write('\u2191'));
      write(')');
    });
    element('div', {'class': 'subindex'}, () {
      element('ul', {}, () {
        for (var type in types) {
          element('li', {}, () => link('type_$type', () => write(type)));
        }
      });
    });
  }

  void generateRefactoringsIndex(Iterable<Refactoring> refactorings) {
    h3(() {
      write("Refactorings");
      write(' (');
      link('refactorings', () => write('\u2191'));
      write(')');
    });
    // TODO: Individual refactorings are not yet hyperlinked.
    element('div', {'class': 'subindex'}, () {
      element('ul', {}, () {
        for (var refactoring in refactorings) {
          element('li', {}, () => link('refactoring_${refactoring.kind}',
            () => write(refactoring.kind)));
        }
      });
    });
  }
}

/**
 * Visitor that generates a compact representation of a type, such as:
 *
 * {
 *   "id": String
 *   "error": optional Error
 *   "result": {
 *     "version": String
 *   }
 * }
 */
class TypeVisitor extends HierarchicalApiVisitor
    with HtmlMixin, HtmlCodeGenerator {
  /**
   * Set of fields which should be shown in boldface, or null if no field
   * should be shown in boldface.
   */
  final Set<String> fieldsToBold;

  /**
   * True if a short description should be generated.  In a short description,
   * objects are shown as simply "object", and enums are shown as "String".
   */
  final bool short;

  TypeVisitor(Api api, {this.fieldsToBold, this.short: false}) : super(api);

  @override
  void visitTypeEnum(TypeEnum typeEnum) {
    if (short) {
      write('String');
      return;
    }
    writeln('enum {');
    indent(() {
      for (TypeEnumValue value in typeEnum.values) {
        writeln(value.value);
      }
    });
    write('}');
  }

  @override
  void visitTypeList(TypeList typeList) {
    write('List<');
    visitTypeDecl(typeList.itemType);
    write('>');
  }

  @override
  void visitTypeMap(TypeMap typeMap) {
    write('Map<');
    visitTypeDecl(typeMap.keyType);
    write(', ');
    visitTypeDecl(typeMap.valueType);
    write('>');
  }

  @override
  void visitTypeObject(TypeObject typeObject) {
    if (short) {
      write('object');
      return;
    }
    writeln('{');
    indent(() {
      for (TypeObjectField field in typeObject.fields) {
        write('"');
        if (fieldsToBold != null && fieldsToBold.contains(field.name)) {
          b(() {
            write(field.name);
          });
        } else {
          write(field.name);
        }
        write('": ');
        if (field.value != null) {
          write(JSON.encode(field.value));
        } else {
          if (field.optional) {
            gray(() {
              write('optional');
            });
            write(' ');
          }
          visitTypeDecl(field.type);
        }
        writeln();
      }
    });
    write('}');
  }

  @override
  void visitTypeReference(TypeReference typeReference) {
    String displayName = typeReference.typeName;
    if (api.types.containsKey(typeReference.typeName)) {
      link('type_${typeReference.typeName}', () {
        write(displayName);
      });
    } else {
      write(displayName);
    }
  }

  @override
  void visitTypeUnion(TypeUnion typeUnion) {
    bool verticalBarNeeded = false;
    for (TypeDecl choice in typeUnion.choices) {
      if (verticalBarNeeded) {
        write(' | ');
      }
      visitTypeDecl(choice);
      verticalBarNeeded = true;
    }
  }
}
