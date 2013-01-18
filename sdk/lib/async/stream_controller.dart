// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of dart.async;

// -------------------------------------------------------------------
// Default implementation of a stream with a controller for adding
// events to the stream.
// -------------------------------------------------------------------

/**
 * A controller and the stream it controls.
 *
 * This controller allows sending data, error and done events on
 * its [stream].
 * This class can be used to create a simple stream that others
 * can listen on, and to push events to that stream.
 *
 * It's possible to check whether the stream is paused or not, and whether
 * it has subscribers or not, as well as getting a callback when either of
 * these change.
 */
class StreamController<T> extends Stream<T> implements StreamSink<T> {
  _StreamImpl<T> _stream;
  Stream<T> get stream => _stream;

  /**
   * A controller with a [stream] that supports multiple subscribers.
   */
  StreamController.multiSubscription() {
    _stream = new _MultiControllerStream<T>(onSubscriptionStateChange,
                                            onPauseStateChange);
  }
  /**
   * A controller with a [stream] that supports only one single subscriber.
   * The controller will buffer all incoming events until the subscriber is
   * registered.
   */
  StreamController() {
    _stream = new _SingleControllerStream<T>(onSubscriptionStateChange,
                                             onPauseStateChange);
  }

  bool get isSingleSubscription => _stream.isSingleSubscription;

  Stream<T> asMultiSubscriptionStream() => _stream.asMultiSubscriptionStream();

  StreamSubscription listen(void onData(T data),
                            { void onError(AsyncError error),
                              void onDone(),
                              bool unsubscribeOnError}) {
    return _stream.listen(onData,
                          onError: onError,
                          onDone: onDone,
                          unsubscribeOnError: unsubscribeOnError);
  }

  /**
   * Returns a view of this object that only exposes the [StreamSink] interface.
   */
  StreamSink<T> get sink => new StreamSinkView<T>(this);

  /** Whether one or more active subscribers have requested a pause. */
  bool get isPaused => _stream._isPaused;

  /** Whether there are currently any subscribers on this [Stream]. */
  bool get hasSubscribers => _stream._hasSubscribers;

  /**
   * Send or queue a data event.
   */
  void add(T value) => _stream._add(value);

  /**
   * Send or enqueue an error event.
   *
   * If [error] is not an [AsyncError], [error] and an optional [stackTrace]
   * is combined into an [AsyncError] and sent this stream's listeners.
   *
   * Otherwise, if [error] is an [AsyncError], it is used directly as the
   * error object reported to listeners, and the [stackTrace] is ignored.
   *
   * If a subscription has requested to be unsubscribed on errors,
   * it will be unsubscribed after receiving this event.
   */
  void signalError(Object error, [Object stackTrace]) {
    AsyncError asyncError;
    if (error is AsyncError) {
      asyncError = error;
    } else {
      asyncError = new AsyncError(error, stackTrace);
    }
    _stream._signalError(asyncError);
  }

  /**
   * Send or enqueue a "done" message.
   *
   * The "done" message should be sent at most once by a stream, and it
   * should be the last message sent.
   */
  void close() { _stream._close(); }

  /**
   * Called when the first subscriber requests a pause or the last a resume.
   *
   * Read [isPaused] to see the new state.
   */
  void onPauseStateChange() {}

  /**
   * Called when the first listener subscribes or the last unsubscribes.
   *
   * Read [hasSubscribers] to see what the new state is.
   */
  void onSubscriptionStateChange() {}

  void forEachSubscriber(void action(_StreamSubscriptionImpl<T> subscription)) {
    _stream._forEachSubscriber(() {
      try {
        action();
      } on AsyncError catch (e) {
        e.throwDelayed();
      } catch (e, s) {
        new AsyncError(e, s).throwDelayed();
      }
    });
  }
}

typedef void _NotificationHandler();

class _MultiControllerStream<T> extends _MultiStreamImpl<T> {
  _NotificationHandler _subscriptionHandler;
  _NotificationHandler _pauseHandler;

  _MultiControllerStream(this._subscriptionHandler, this._pauseHandler);

  void _onSubscriptionStateChange() {
    _subscriptionHandler();
  }

  void _onPauseStateChange() {
    _pauseHandler();
  }
}

class _SingleControllerStream<T> extends _SingleStreamImpl<T> {
  _NotificationHandler _subscriptionHandler;
  _NotificationHandler _pauseHandler;

  _SingleControllerStream(this._subscriptionHandler, this._pauseHandler);

  void _onSubscriptionStateChange() {
    _subscriptionHandler();
  }

  void _onPauseStateChange() {
    _pauseHandler();
  }
}