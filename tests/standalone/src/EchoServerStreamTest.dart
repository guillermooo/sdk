// Copyright (c) 2011, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// Echo server test program to test socket streams.
//
// VMOptions=
// VMOptions=--short_socket_read
// VMOptions=--short_socket_write
// VMOptions=--short_socket_read --short_socket_write

class EchoServerStreamTest {

  static void testMain() {
    EchoServerGame echoServerGame = new EchoServerGame.start();
  }
}

class EchoServerGame {

  static final MSGSIZE = 10;
  static final SERVERINIT = 0;
  static final SERVERSHUTDOWN = -1;
  static final MESSAGES = 100;
  static final FIRSTCHAR = 65;

  EchoServerGame.start()
      : _receivePort = new ReceivePort(),
        _sendPort = null,
        _buffer = new List<int>(MSGSIZE),
        _messages = 0 {
    for (int i = 0; i < MSGSIZE; i++) {
      _buffer[i] = FIRSTCHAR + i;
    }
    new EchoServer().spawn().then((SendPort port) {
      _sendPort = port;
      start();
    });
  }

  void sendData() {

    void closeHandler() {
      _socket.close();
    }

    void errorHandler() {
      Expect.fail("Socket error");
    }

    void connectHandler() {

      SocketOutputStream stream = _socket.outputStream;

      void dataSent() {
        InputStream inputStream = _socket.inputStream;
        int offset = 0;
        List<int> data;

        void dataReceived() {
          // Test both read and readInto.
          int bytesRead = 0;
          if (_messages % 2 == 0) {
            bytesRead = inputStream.readInto(data, offset, MSGSIZE - offset);
            for (int i = 0; i < offset + bytesRead; i++) {
              Expect.equals(FIRSTCHAR + i, data[i]);
            }
          } else {
            data = inputStream.read();
            bytesRead = data.length;
            for (int i = 0; i < data.length; i++) {
              Expect.equals(FIRSTCHAR + i + offset, data[i]);
            }
          }

          offset += bytesRead;
          if (offset == MSGSIZE) {
            _messages++;
            _socket.close();
            if (_messages < MESSAGES) {
              sendData();
            } else {
              shutdown();
            }
          }
        }

        if (_messages % 2 == 0) data = new List<int>(MSGSIZE);
        inputStream.dataHandler = dataReceived;
      }

      _socket.closeHandler = closeHandler;
      _socket.errorHandler = errorHandler;

      // Test both write and writeFrom in different forms.
      switch (_messages % 2) {
        case 0:
          stream.write(_buffer);
          break;
        case 1:
          stream.write(_buffer, false);
          break;
        case 2:
          stream.writeFrom(_buffer);
          break;
        case 3:
          stream.writeFrom(_buffer, len: _buffer.length ~/ 2);
          stream.writeFrom(_buffer, _buffer.length ~/ 2);
          break;
      }
      stream.close();
      dataSent();
    }

    _socket = new Socket(EchoServer.HOST, _port);
    if (_socket !== null) {
      _socket.connectHandler = connectHandler;
    } else {
      Expect.fail("socket creation failed");
    }
  }

  void start() {
    _receivePort.receive((var message, SendPort replyTo) {
      _port = message;
      sendData();
    });
    _sendPort.send(SERVERINIT, _receivePort.toSendPort());
  }

  void shutdown() {
    _sendPort.send(SERVERSHUTDOWN, _receivePort.toSendPort());
    _receivePort.close();
  }

  int _port;
  ReceivePort _receivePort;
  SendPort _sendPort;
  Socket _socket;
  List<int> _buffer;
  int _messages;
}

class EchoServer extends Isolate {

  static final HOST = "127.0.0.1";
  static final int MSGSIZE = EchoServerGame.MSGSIZE;

  void main() {

    void connectionHandler() {
      Socket _client;
      InputStream inputStream;
      List<int> buffer = new List<int>(MSGSIZE);
      int offset = 0;

      void dataReceived() {
        SocketOutputStream outputStream;
        int bytesRead;
        outputStream = _client.outputStream;
        bytesRead = inputStream.readInto(buffer, offset, MSGSIZE - offset);
        if (bytesRead > 0) {
          offset += bytesRead;
          for (int i = 0; i < offset; i++) {
            Expect.equals(EchoServerGame.FIRSTCHAR + i, buffer[i]);
          }
          if (offset == MSGSIZE) {
            outputStream.write(buffer);
            outputStream.close();
          }
        }
      }

      void errorHandler() {
        Expect.fail("Socket error");
      }

      _client = _server.accept();
      inputStream = _client.inputStream;
      inputStream.dataHandler = dataReceived;
      _client.errorHandler = errorHandler;
    }

    void errorHandlerServer() {
      Expect.fail("Server socket error");
    }

    this.port.receive((message, SendPort replyTo) {
      if (message == EchoServerGame.SERVERINIT) {
        _server = new ServerSocket(HOST, 0, 10);
        Expect.equals(true, _server !== null);
        _server.connectionHandler = connectionHandler;
        _server.errorHandler = errorHandlerServer;
        replyTo.send(_server.port, null);
      } else if (message == EchoServerGame.SERVERSHUTDOWN) {
        _server.close();
        this.port.close();
      }
    });
  }

  ServerSocket _server;
}

main() {
  EchoServerStreamTest.testMain();
}