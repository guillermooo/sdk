library WebDBTest;
import '../../pkg/unittest/lib/unittest.dart';
import '../../pkg/unittest/lib/html_config.dart';
import 'dart:html';

void fail(message) {
  guardAsync(() {
      expect(false, isTrue, reason: message);
    });
}

Future<SqlTransaction> createTransaction(Database db) {
  final completer = new Completer<SqlTransaction>();

  db.transaction((SqlTransaction transaction) {
    completer.complete(transaction);
  });

  return completer.future;
}

createTable(tableName, columnName) => (SqlTransaction transaction) {
  final completer = new Completer<SqlTransaction>();

  final sql = 'CREATE TABLE $tableName ($columnName)';
  transaction.executeSql(sql, [],
    (SqlTransaction tx, SqlResultSet rs) {
      completer.complete(transaction);
    },
    (SqlTransaction tx, SqlError error) {
      fail(error.message);
    });

  return completer.future;
};

insert(tableName, columnName, value) => (SqlTransaction transaction) {
  final completer = new Completer<SqlTransaction>();

  final sql = 'INSERT INTO $tableName ($columnName) VALUES (?)';
  transaction.executeSql(sql, [value],
    (SqlTransaction tx, SqlResultSet rs) {
      completer.complete(tx);
    },
    (SqlTransaction tx, SqlError error) {
      fail(error.message);
    });

  return completer.future;
};

queryTable(tableName, callback) => (SqlTransaction transaction) {
  final completer = new Completer<SqlTransaction>();

  final sql = 'SELECT * FROM $tableName';
  transaction.executeSql(sql, [],
    (SqlTransaction tx, SqlResultSet rs) {
      callback(rs);
      completer.complete(tx);
    },
    (SqlTransaction tx, SqlError error) {
      fail(error.message);
    });

  return completer.future;
};

dropTable(tableName, [bool ignoreFailure = false]) =>
    (SqlTransaction transaction) {
  final completer = new Completer<SqlTransaction>();

  final sql = 'DROP TABLE $tableName';
  transaction.executeSql(sql, [],
    (SqlTransaction tx, SqlResultSet rs) {
      completer.complete(tx);
    },
    (SqlTransaction tx, SqlError error) {
      if (ignoreFailure) {
        completer.complete(tx);
      } else {
        fail(error.message);
      }
    });

  return completer.future;
};

main() {
  useHtmlConfiguration();

  test('Web Database', () {
    final tableName = 'test_table';
    final columnName = 'test_data';

    final db = window.openDatabase('test_db', '1.0', 'test_db', 1024 * 1024);

    expect(db, isNotNull, reason: 'Unable to open database');

    createTransaction(db)
      // Attempt to clear out any tables which may be lurking from previous
      // runs.
      .chain(dropTable(tableName, true))
      .chain(createTable(tableName, columnName))
      .chain(insert(tableName, columnName, 'Some text data'))
      .chain(queryTable(tableName, (resultSet) {
        guardAsync(() {
          expect(resultSet.rows.length, 1);
          var row = resultSet.rows.item(0);
          expect(row.containsKey(columnName), isTrue);
          expect(row[columnName], 'Some text data');
        });
      }))
      .chain(dropTable(tableName))
      .then(expectAsync1((tx) {}));
  });
}