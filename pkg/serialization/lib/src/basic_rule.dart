// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of serialization;

// TODO(alanknight): Figure out how to reasonably separate out the things
// that require reflection without making the API more awkward. Or if that is
// in fact necessary. Maybe the tree-shaking will just remove it if unused.

/**
 * This is the basic rule for handling "normal" objects, which have a list of
 * fields and a constructor, as opposed to simple types or collections. It uses
 * mirrors to access the state, and can also use them to figure out the list
 * of fields and the constructor if it's not provided.
 *
 * If you call [Serialization.addRule], this is what you get.
 *
 */
class BasicRule extends SerializationRule {
  /**
   * The [type] is used both to find fields and to verify if the object is one
   * that we handle.
   */
  final ClassMirror type;

  /** Used to create new objects when reading. */
  Constructor constructor;

  /** This holds onto our list of fields, and can also calculate them. */
  _FieldList fields;

  /**
   * Instances can either use maps or lists to hold the object's state. The list
   * representation is much more compact and used by default. The map
   * representation is more human-readable. The default is to use lists.
   */
  bool useMaps = false;

  // TODO(alanknight) Change the type parameter once we have class literals.
  // Issue 6282.
  // TODO(alanknight) Does the comment for this format properly?
  /**
   * Create this rule. Right now the user is obliged to pass a ClassMirror,
   * but once we allow class literals (Issue 6282) it will support that. The
   * other parameters can all be left as null, and are optional on the
   * [Serialization.addRule] method which is the normal caller for this.
   * [constructorName] is the constructor, if not the default.
   * [constructorFields] are the fields required to call the constructor, which
   *   is the essential state. They don't have to be actual fields,
   *   getter/setter pairs or getter/constructor pairs are fine. Note that
   *   the constructorFields do not need to be strings, they can be arbitrary
   *   values. For non-strings, these will be treated as constant values to be
   *   used instead of data read from the objects.
   * [regularFields] are the non-essential fields. They don't have to be actual
   *   fields, getter/setter pairs are fine. If this is null, it's assumed
   *   that we should figure them out.
   * [excludeFields] lets you tell it to find the fields automatically, but
   *   omit some that would otherwise be included.
   */
  BasicRule(ClassMirror this.type, String constructorName,
      List constructorFields, List regularFields,
      List excludeFields) {
    _findFields(constructorFields, regularFields, excludeFields);
    constructor = new Constructor(
        type, constructorName, fields.constructorFieldIndices());
    configureForLists();
  }

  /**
   * Sometimes it's necessary to treat fields of an object differently, based
   * on the containing object. For example, by default a list treats its
   * contents as non-essential state, so it will be populated only after all
   * objects have been created. An object may have a list which is used in its
   * constructor and must be fully created before the owning object can be
   * created. Alternatively, it may not be possible to set a field directly,
   * and some other method must be called to set it, perhaps calling a method
   * on the owning object to add each individual element.
   *
   * This method lets you designate a function to use to set the value of a
   * field. It also makes the contents of that field be treated as essential,
   * which currently only has meaning if the field is a list. This is done
   * because you might set a list field's special treatment function to add
   * each item individually and that will only work if those objects already
   * exist.
   *
   * For example, to serialize a Serialization, we need its rules to be
   * individually added rather than just setting the rules field.
   *      ..addRuleFor(new Serialization()).setFieldWith('rules',
   *          (InstanceMirror s, List rules) {
   *            rules.forEach((x) => s.reflectee.addRule(x));
   * Note that the function is passed the owning object as well as the field
   * value, but that it is passed as a mirror.
   */
  setFieldWith(String fieldName, SetWithFunction setWith) {
    fields.addAllByName([fieldName]);
    _NamedField field = fields.named(fieldName);
    Function setter = (setWith == null) ? field.defaultSetter : setWith;
    field.customSetter = setter;
  }

  /** Return the name of the constructor used to create new instances on read.*/
  String get constructorName => constructor.name;

  /** Return the list of field names to be passed to the constructor.*/
  List<String> get constructorFields => fields.constructorFieldNames();

  /** Return the list of field names not used in the constructor. */
  List<String> get regularFields => fields.regularFieldNames();

  String toString() => "Basic Rule for ${type.simpleName}";

  /**
   * Configure this instance to use maps by field name as its output.
   * Instances can either produce maps or lists. The list representation
   * is much more compact and used by default. The map representation is
   * much easier to debug. The default is to use lists.
   */
  configureForMaps() {
    useMaps = true;
  }

  /**
   * Configure this instance to use lists accessing fields by index as its
   * output. Instances can either produce maps or lists. The list representation
   * is much more compact and used by default. The map representation is
   * much easier to debug. The default is to use lists.
   */
  configureForLists() {
    useMaps = false;
  }

  /** Create either a list or a map to hold the object's state, depending
   * on the [useMaps] variable. If using a Map, we wrap it in order to keep
   * the protocol compatible. See [configureForLists]/[configureForMaps].
   */
   createStateHolder() =>
     useMaps ? new _MapWrapper(fields.contents) : new List(fields.length);

  /** Wrap the state if it's passed in as a map. */
  makeIndexableByNumber(state) =>
      (state is Map) ? new _MapWrapper.fromMap(state, fields.contents) : state;

  /**
   * Extract the state from [object] using an instanceMirror and the field
   * names in [fields]. Call the function [callback] on each value.
   */
  extractState(object, Function callback) {
    var result = createStateHolder();
    var mirror = reflect(object);

    keysAndValues(fields).forEach(
        (index, field) {
          var value = _value(mirror, field);
          callback(checkForEssentialLists(index, value));
          result[index] = value;
        });
    return _unwrap(result);
  }

  /**
   * If the value is a List, and the field is a constructor field or
   * otherwise specially designated, we wrap it in something that indicates
   * a restriction on the rules that can be used. Which in this case amounts
   * to designating the rule, since we so far only have one rule per object.
   */
  checkForEssentialLists(index, value) {
    if (value is List && fields.contents[index].isEssential) {
      return new DesignatedRuleForObject(value,
          (SerializationRule rule) => rule is ListRuleEssential);
    } else {
      return value;
    }
  }

  /** Remove any MapWrapper from the extracted state. */
  _unwrap(result) => (result is _MapWrapper) ? result.asMap() : result;

  /**
   * Call the designated constructor with the appropriate fields from [state],
   * first resolving references in the context of [reader].
   */
  inflateEssential(state, Reader reader) {
    InstanceMirror mirror = constructor.constructFrom(
        makeIndexableByNumber(state), reader);
    return mirror.reflectee;
  }

  /** For all [state] not required in the constructor, set it in the [object],
   * resolving references in the context of [reader].
   */
  inflateNonEssential(rawState, object, Reader reader) {
    InstanceMirror mirror = reflect(object);
    var state = makeIndexableByNumber(rawState);
    fields.forEachRegularField( (_Field field) {
      var value = reader.inflateReference(state[field.index]);
      field.setValue(mirror, value);
    });
  }

  /**
   * Determine if this rule applies to the object in question. In our case
   * this is true if the type mirrors are the same.
   */
  // TODO(alanknight): This seems likely to be slow. Verify. Other options?
  bool appliesTo(object, Writer w) => reflect(object).type == type;

  /**
   * Given the various field lists provided by the user, construct the list
   * of field names that we want.
   */
  void _findFields(List constructorFields, List regularFields,
      List excludeFields) {
    fields = new _FieldList(type);
    fields.constructorFields = constructorFields;
    fields.regular = regularFields;
    // TODO(alanknight): The order of this matters. It shouldn't.
    fields.exclude = excludeFields;
    fields.figureOutFields();
  }

  /**
   * Extract the value of the field [fieldName] from the object reflected
   * by [mirror].
   */
  // TODO(alanknight): The framework should be resilient if there are fields
  // it expects that are missing, either for the case of de-serializing to a
  // different definition, or for the case that tree-shaking has removed state.
  // TODO(alanknight): This, and other places, rely on synchronous access to
  // mirrors. Should be changed to use a synchronous API once one is available,
  // or to be async, but that would be extremely ugly.
  _value(InstanceMirror mirror, _Field field) => field.valueIn(mirror);

  /**
   * When reading from a flat format we are given [stream] and need to pull as
   * much data from it as we need. Our format is that we have an integer N
   * indicating the number of objects and then for each object N fields, which
   * are references, where a reference is stored in the stream as two integers.
   * Or, in the special case of null, two nulls.
   */
  pullStateFrom(Iterator stream) {
    var dataLength = stream.next();
    var ruleData = new List();
    for (var i = 0; i < dataLength; i++) {
      var subList = new List();
      ruleData.add(subList);
      for (var j = 0; j < fields.length; j++) {
        var a = stream.next();
        var b = stream.next();
        if (!(a is int)) {
          // This wasn't a reference, so just use the first object as a literal.
          // particularly used for the case of null.
          subList.add(a);
        } else {
          subList.add(new Reference(this, a, b));
        }
      }
    }
    return ruleData;
  }
}

/**
 * This represents a field in an object. It is intended to be used as part of
 * a [_FieldList].
 */
abstract class _Field implements Comparable {

  /** The FieldList that contains us. */
  final _FieldList fieldList;

  /**
   * Our position in the [contents] collection of [fieldList]. This is used
   * to index into the state, so it's extremely important.
   */
  int index;

  /** Is this field used in the constructor? */
  bool usedInConstructor = false;

  /**
   * Create a new [_Field] instance. This will be either a [_NamedField] or a
   * [_ConstantField] depending on whether or not [value] corresponds to a
   * field in the class which [fieldList] models.
   */
  factory _Field(value, _FieldList fieldList) {
    if (_isReallyAField(value, fieldList)) {
      return new _NamedField._internal(value, fieldList);
    } else {
      return new _ConstantField._internal(value, fieldList);
    }
  }

  /**
   * Determine if [value] represents a field or getter in the class that
   * [fieldList] models.
   */
  static bool _isReallyAField(value, _FieldList fieldList) {
    if (!(value is String)) return false;
    return hasField(value, fieldList.mirror) ||
        hasGetter(value, fieldList.mirror);
  }

  /** Private constructor. */
  _Field._internal(this.fieldList);

  /**
   * Extracts the value for the field that this represents from the instance
   * mirrored by [mirror] and return it.
   */
  valueIn(InstanceMirror mirror);

  // TODO(alanknight): Is this the right name, or is it confusing that essential
  // is not the inverse of regular.
  /** Return true if this is field is not used in the constructor. */
  bool get isRegular => !usedInConstructor;

  /**
   * Return true if this field is treated as essential state, either because
   * it is used in the constructor, or because it's been designated
   * using [setFieldWith].
   */
  bool get isEssential => usedInConstructor;

  /** Set the [value] of our field in the given mirrored [object]. */
  void setValue(InstanceMirror object, value);

  // Because [x] may not be a named field, we compare the toString. We don't
  // care that much where constants come in the sort order as long as it's
  // consistent.
  compareTo(_Field x) => toString().compareTo(x.toString());
}

/**
 * This represents a field in the object, either stored as a field or
 * accessed via getter/setter/constructor parameter. It has a name and
 * will attempt to access the state for that name using an [InstanceMirror].
 */
class _NamedField extends _Field {
  /** The name of the field (or getter) */
  final name;

  /** The special way to set this value registered, if this has a value. */
  Function customSetter;

  _NamedField._internal(this.name, fieldList) : super._internal(fieldList);

  operator ==(x) => x is _NamedField && (name == x.name);
  int get hashCode => name.hashCode;

  /**
   * Return true if this field is treated as essential state, either because
   * it is used in the constructor, or because it's been designated
   * using [setFieldWith].
   */
  bool get isEssential => super.isEssential || customSetter != null;

  /** Set the [value] of our field in the given mirrored [object]. */
  void setValue(InstanceMirror object, value) {
    setter(object, value);
  }

  valueIn(InstanceMirror mirror) => mirror.getField(name).value.reflectee;

  /** Return the function to use to set our value. */
  Function get setter =>
      (customSetter != null) ? customSetter : defaultSetter;

  /** Return a default setter function. */
  void defaultSetter(InstanceMirror object, value) {
    object.setField(name, reflect(value));
  }

  String toString() => 'Field($name)';
}

/**
 * This represents a constant value that will be passed as a constructor
 * parameter. Rather than having a name it has a constant value.
 */
class _ConstantField extends _Field {

  /** The value we always return.*/
  final value;

  _ConstantField._internal(this.value, fieldList) : super._internal(fieldList);

  operator ==(x) => x is _ConstantField && (value == x.value);
  int get hashCode => value.hashCode;
  String toString() => 'ConstantField($value)';
  valueIn(InstanceMirror mirror) => value;

  /** We cannot be set, so setValue is a no-op. */
  void setValue(InstanceMirror object, value) {}

  /** There are places where the code expects us to have an identifier, so
   * use the value for that.
   */
  get name => value;
}

/**
 * The organization of fields in an object can be reasonably complex, so they
 * are kept in a separate object, which also has the ability to compute the
 * default fields to use reflectively.
 */
class _FieldList implements Iterable {
  /**
   * All of our fields, indexed by name. Note that the names are not
   * necessarily strings.
   */
  Map<dynamic, _Field> allFields = new Map<dynamic, _Field>();

  /**
   * The fields which are used in the constructor. The fields themselves also
   * know if they are constructor fields or not, but we need to keep this
   * information here because the order matters.
   */
  List _constructorFields = const [];

  /** The list of fields to exclude if we are computing the list ourselves. */
  List<String> _excludeFields = const [];

  /** The mirror we will use to compute the fields. */
  final ClassMirror mirror;

  /** Cached, sorted list of fields. */
  List<_Field> _contents;

  /** Should we compute the fields or just use whatever we were given. */
  bool _shouldFigureOutFields = true;

  _FieldList(this.mirror);

  /** Look up a field by [name]. */
  _Field named(String name) => allFields[name];

  /** Set the fields to be used in the constructor. */
  set constructorFields(List fieldNames) {
    if (fieldNames == null || fieldNames.isEmpty) return;
    _constructorFields = [];
    for (var each in fieldNames) {
      var field = new _Field(each, this)..usedInConstructor = true;
      allFields[each] = field;
      _constructorFields.add(field);
    }
    invalidate();
  }

  /** Set the fields that aren't used in the constructor. */
  set regular(List<String> fields) {
    if (fields == null) return;
    _shouldFigureOutFields = false;
    addAllByName(fields);
  }

  /** Set the fields to be excluded. This is mutually exclusive with setting
   * the regular fields.
   */
  set exclude(List<String> fields) {
    // TODO(alanknight): This isn't well tested.
    if (fields == null || fields.isEmpty) return;
    if (allFields.length > _constructorFields.length) {
      throw "You can't specify both excludeFields and regular fields";
    }
    _excludeFields = fields;
  }

  int get length => allFields.length;

  /** Add all the fields which aren't on the exclude list. */
  void addAllNotExplicitlyExcluded(List<String> aCollection) {
    if (aCollection == null) return;
    var names = aCollection;
    names = names.filter((x) => !_excludeFields.contains(x));
    addAllByName(names);
  }

  /** Add all the fields with the given names without any special properties. */
  void addAllByName(List<String> names) {
    for (var each in names) {
      allFields.putIfAbsent(each, () => new _Field(each, this));
    }
    invalidate();
  }

  /**
   * Fields have been added. In case we had already forced calculation of the
   * list of contents, re-set it.
   */
  void invalidate() {
    _contents = null;
    contents;
  }

  Iterator iterator() => contents.iterator();

  /** Return a cached, sorted list of all the fields. */
  List<_Field> get contents {
    if (_contents == null) {
      _contents = sorted(allFields.values);
      for (var i = 0; i < _contents.length; i++)
        _contents[i].index = i;
    }
    return _contents;
  }

  /** Iterate over the regular fields, i.e. those not used in the constructor.*/
  void forEachRegularField(Function f) {
    for (var each in contents) {
      if (each.isRegular) {
        f(each);
      }
    }
  }

  /** Iterate over the fields used in the constructor. */
  void forEachConstructorField(Function f) {
    for (var each in contents) {
      if (each.usedInConstructor) {
        f(each);
      }
    }
  }

  List get constructorFields => _constructorFields;
  List constructorFieldNames() => constructorFields.map((x) => x.name);
  List constructorFieldIndices() => constructorFields.map((x) => x.index);
  List regularFields() => contents.filter((x) => !x.usedInConstructor);
  List regularFieldNames() => regularFields().map((x) => x.name);
  List regularFieldIndices() => regularFields().map((x) => x.index);


  /**
   * If we weren't given any non-constructor fields to use, figure out what
   * we think they ought to be, based on the class definition.
   * We find public fields, getters that have corresponding setters, and getters
   * that are listed in the constructor fields.
   */
  void figureOutFields() {
    List names(Collection<DeclarationMirror> mirrors) =>
        mirrors.map((each) => each.simpleName);

    if (!_shouldFigureOutFields || !regularFields().isEmpty) return;
    var fields = publicFields(mirror);
    var getters = publicGetters(mirror);
    var gettersWithSetters = getters.filter( (each)
        => mirror.setters["${each.simpleName}="] != null);
    var gettersThatMatchConstructor = getters.filter((each)
        => (named(each.simpleName) != null) &&
            (named(each.simpleName).usedInConstructor));
    addAllNotExplicitlyExcluded(names(fields));
    addAllNotExplicitlyExcluded(names(gettersWithSetters));
    addAllNotExplicitlyExcluded(names(gettersThatMatchConstructor));
  }
}

/**
 *  Provide a typedef for the setWith argument to setFieldWith. It would
 * be nice if we could put this closer to the definition.
 */
typedef SetWithFunction(InstanceMirror m, object);

/**
 * This represents a constructor that is to be used when re-creating a
 * serialized object.
 */
class Constructor {
  /** The mirror of the class we construct. */
  final ClassMirror type;

  /** The name of the constructor to use, if not the default constructor.*/
  String name;

  /**
   * The indices of the fields used as constructor arguments. We will look
   * these up in the state by number. These correspond to the index in the
   * [contents] of the FieldList, which will be alphabetically sorted.
   */
  List<int> fieldNumbers;

  /**
   * Creates a new constructor for the [type] with the constructor named [name]
   * and the [fieldNumbers] of the constructor fields.
   */
  Constructor(this.type, this.name, this.fieldNumbers) {
    if (name == null) name = '';
    if (fieldNumbers == null) fieldNumbers = const [];
  }

  /**
   * Find the field values in [state] and pass them to the constructor.
   * If any of [fieldNumbers] is not an int, then use it as a literal value.
   */
  constructFrom(state, Reader r) {
    // TODO(alanknight): Handle named parameters
    Collection inflated = fieldNumbers.map(
        (x) => (x is int) ? reflect(r.inflateReference(state[x])) : reflect(x));
    var result = type.newInstance(name, inflated);
    return result.value;
  }
}

/**
 * This wraps a map to make it indexable by integer field numbers. It translates
 * from the index into a field name and then looks it up in the map.
 */
class _MapWrapper {
  Map<String, dynamic> _map = new Map<String, dynamic>();
  List fieldList;
  _MapWrapper(this.fieldList);
  _MapWrapper.fromMap(this._map, this.fieldList);

  operator [](key) => _map[fieldList[key].name];
  operator []=(key, value) { _map[fieldList[key].name] = value; }
  get length => _map.length;

  asMap() => _map;
}