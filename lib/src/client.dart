import 'dart:async';

import 'package:centrifuge/src/transport.dart';
import 'package:centrifuge/src/server_subscription.dart';
import 'package:meta/meta.dart';
import 'package:protobuf/protobuf.dart';

import 'client_config.dart';
import 'events.dart';
import 'proto/client.pb.dart';
import 'subscription.dart';
import 'transport.dart';

Client createClient(String url, {ClientConfig? config}) => ClientImpl(
      url,
      config ?? ClientConfig(),
      protobufTransportBuilder,
    );

abstract class Client {
  Stream<ConnectEvent> get connectStream;

  Stream<DisconnectEvent> get disconnectStream;

  Stream<MessageEvent> get messageStream;

  Stream<ServerSubscribeEvent> get serverSubscribeStream;

  Stream<ServerUnsubscribeEvent> get serverUnsubscribeStream;

  Stream<ServerPublishEvent> get serverPublishStream;

  Stream<ServerJoinEvent> get serverJoinStream;

  Stream<ServerLeaveEvent> get serverLeaveStream;

  /// Connect to the server.
  ///
  void connect();

  /// Set token for connection request.
  ///
  /// Whenever the client connects to a server, it adds token to the
  /// connection request.
  ///
  /// To remove previous token, call with null.
  void setToken(String token);

  /// Set data for connection request.
  ///
  /// Whenever the client connects to a server, it adds connectData to the
  /// connection request.
  ///
  /// To remove previous connectData, call with null.
  void setConnectData(List<int> connectData);

  /// Publish data to the channel
  ///
  Future publish(String channel, List<int> data);

  /// Send RPC command
  ///
  Future<RPCResult> rpc(List<int> data);

  @alwaysThrows
  Future<void> send(List<int> data);

  /// Disconnect from the server.
  ///
  void disconnect();

  /// Detect that the subscription already exists.
  ///
  bool hasSubscription(String channel);

  /// Get subscription to the channel.
  ///
  /// You need to call [Subscription.subscribe] to start receiving events
  /// in the channel.
  Subscription getSubscription(String channel);

  /// Remove the [subscription] and unsubscribe from [subscription.channel].
  ///
  void removeSubscription(Subscription subscription);
}

class ClientImpl implements Client, GeneratedMessageSender {
  ClientImpl(this._url, this._config, this._transportBuilder);

  final TransportBuilder _transportBuilder;
  final _subscriptions = <String, SubscriptionImpl>{};
  final _serverSubs = <String, ServerSubscription>{};

  late Transport _transport;
  String? _token;

  final String _url;
  ClientConfig _config;

  ClientConfig? get config => _config;
  List<int>? _connectData;
  String? _clientID;

  final _connectController = StreamController<ConnectEvent>.broadcast();
  final _disconnectController = StreamController<DisconnectEvent>.broadcast();
  final _messageController = StreamController<MessageEvent>.broadcast();
  final _serverSubscribeController =
      StreamController<ServerSubscribeEvent>.broadcast();
  final _serverUnsubscribeController =
      StreamController<ServerUnsubscribeEvent>.broadcast();
  final _serverPublishController =
      StreamController<ServerPublishEvent>.broadcast();
  final _serverJoinController = StreamController<ServerJoinEvent>.broadcast();
  final _serverLeaveController = StreamController<ServerLeaveEvent>.broadcast();

  _ClientState _state = _ClientState.disconnected;

  @override
  Stream<ConnectEvent> get connectStream => _connectController.stream;

  @override
  Stream<DisconnectEvent> get disconnectStream => _disconnectController.stream;

  @override
  Stream<MessageEvent> get messageStream => _messageController.stream;

  @override
  Stream<ServerSubscribeEvent> get serverSubscribeStream =>
      _serverSubscribeController.stream;

  @override
  Stream<ServerUnsubscribeEvent> get serverUnsubscribeStream =>
      _serverUnsubscribeController.stream;

  @override
  Stream<ServerPublishEvent> get serverPublishStream =>
      _serverPublishController.stream;

  @override
  Stream<ServerJoinEvent> get serverJoinStream => _serverJoinController.stream;

  @override
  Stream<ServerLeaveEvent> get serverLeaveStream =>
      _serverLeaveController.stream;

  @override
  void connect() async {
    return _connect();
  }

  bool get connected => _state == _ClientState.connected;

  @override
  void setToken(String token) => _token = token;

  @override
  void setConnectData(List<int> connectData) => _connectData = connectData;

  @override
  Future publish(String channel, List<int> data) async {
    final request = PublishRequest()
      ..channel = channel
      ..data = data;

    await _transport.sendMessage(request, PublishResult());
  }

  @override
  Future<RPCResult> rpc(List<int> data) => _transport.sendMessage(
        RPCRequest()..data = data,
        RPCResult(),
      );

  @override
  @alwaysThrows
  Future<void> send(List<int> data) async {
    throw UnimplementedError;
  }

  @override
  void disconnect() async {
    _processDisconnect(reason: 'manual disconnect', reconnect: false);
    await _transport.close();
  }

  @override
  bool hasSubscription(String channel) {
    return _subscriptions.containsKey(channel);
  }

  @override
  Subscription getSubscription(String channel) {
    if (hasSubscription(channel)) {
      return _subscriptions[channel]!;
    }

    final subscription = SubscriptionImpl(channel, this);

    _subscriptions[channel] = subscription;

    return subscription;
  }

  @override
  Future<void> removeSubscription(Subscription subscription) async {
    final String channel = subscription.channel;
    subscription.unsubscribe();
    _subscriptions.remove(channel);
  }

  Future<UnsubscribeEvent> unsubscribe(String channel) async {
    final request = UnsubscribeRequest()..channel = channel;
    await _transport.sendMessage(request, UnsubscribeResult());
    return UnsubscribeEvent();
  }

  @override
  Future<Rep>
      sendMessage<Req extends GeneratedMessage, Rep extends GeneratedMessage>(
              Req request, Rep result) =>
          _transport.sendMessage(request, result);

  int _retryCount = 0;

  void _processDisconnect(
      {required String reason, required bool reconnect}) async {
    if (_state == _ClientState.disconnected) {
      return;
    }
    _clientID = '';

    if (_state == _ClientState.connected) {
      _subscriptions.values.forEach((s) => s.sendUnsubscribeEventIfNeeded());
      _serverSubs.forEach((key, value) {
        final event = ServerUnsubscribeEvent.from(key);
        _serverUnsubscribeController.add(event);
      });
      final disconnect = DisconnectEvent(reason, reconnect);
      _disconnectController.add(disconnect);
    }

    if (reconnect) {
      _state = _ClientState.connecting;
      _retryCount += 1;
      await _config.retry(_retryCount);
      _connect();
    } else {
      _state = _ClientState.disconnected;
    }
  }

  Future<void> _connect() async {
    try {
      _state = _ClientState.connecting;

      _transport = _transportBuilder(
          url: _url,
          config: TransportConfig(
              headers: _config.headers, pingInterval: _config.pingInterval));

      await _transport.open(
        _onPush,
        onError: (dynamic error) =>
            _processDisconnect(reason: error.toString(), reconnect: true),
        onDone: (reason, reconnect) =>
            _processDisconnect(reason: reason, reconnect: reconnect),
      );

      final request = ConnectRequest();
      if (_token != null) {
        request.token = _token!;
      }

      if (_connectData != null) {
        request.data = _connectData!;
      }

      request.name = _config.name;
      request.version = _config.version;

      if (_serverSubs.isNotEmpty) {
        _serverSubs.forEach((key, value) {
          final subRequest = SubscribeRequest();
          subRequest.offset = value.offset;
          subRequest.epoch = value.epoch;
          subRequest.recover = value.recoverable;
          request.subs.putIfAbsent(key, () => subRequest);
        });
      }

      final result = await _transport.sendMessage(
        request,
        ConnectResult(),
      );

      _clientID = result.client;
      _retryCount = 0;
      _state = _ClientState.connected;
      _connectController.add(ConnectEvent.from(result));

      result.subs.forEach((key, value) {
        final isResubscribed = _serverSubs[key] != null;
        _serverSubs[key] = ServerSubscription(
            key, value.recoverable, value.offset, value.epoch);
        final event = ServerSubscribeEvent.fromSubscribeResult(
            key, value, isResubscribed);
        _serverSubscribeController.add(event);
        value.publications.forEach((element) {
          final event = ServerPublishEvent.from(key, element);
          _serverPublishController.add(event);
        });
      });
      _serverSubs.forEach((key, value) {
        if (!result.subs.containsKey(key)) {
          _serverSubs.remove(key);
        }
      });

      for (SubscriptionImpl subscription in _subscriptions.values) {
        subscription.resubscribeIfNeeded();
      }
    } catch (ex) {
      _processDisconnect(reason: ex.toString(), reconnect: true);
    }
  }

  void _onPush(Push push) {
    switch (push.type) {
      case Push_PushType.PUBLICATION:
        final pub = Publication.fromBuffer(push.data);
        final subscription = _subscriptions[push.channel];
        if (subscription != null) {
          final event = PublishEvent.from(pub);
          subscription.addPublish(event);
          break;
        }
        final serverSubscription = _serverSubs[push.channel];
        if (serverSubscription != null) {
          final event = ServerPublishEvent.from(push.channel, pub);
          _serverPublishController.add(event);
        }
        break;
      case Push_PushType.LEAVE:
        final leave = Leave.fromBuffer(push.data);
        final subscription = _subscriptions[push.channel];
        if (subscription != null) {
          final event = LeaveEvent.from(leave.info);
          subscription.addLeave(event);
          break;
        }
        final serverSubscription = _serverSubs[push.channel];
        if (serverSubscription != null) {
          final event = ServerLeaveEvent.from(push.channel, leave.info);
          _serverLeaveController.add(event);
        }
        break;
      case Push_PushType.JOIN:
        final join = Join.fromBuffer(push.data);
        final subscription = _subscriptions[push.channel];
        if (subscription != null) {
          final event = JoinEvent.from(join.info);
          subscription.addJoin(event);
          break;
        }
        final serverSubscription = _serverSubs[push.channel];
        if (serverSubscription != null) {
          final event = ServerJoinEvent.from(push.channel, join.info);
          _serverJoinController.add(event);
        }
        break;
      case Push_PushType.MESSAGE:
        final message = Message.fromBuffer(push.data);
        final event = MessageEvent(message.data);
        _messageController.add(event);
        break;
      case Push_PushType.SUBSCRIBE:
        final subscribe = Subscribe.fromBuffer(push.data);
        final event = ServerSubscribeEvent.fromSubscribePush(
            push.channel, subscribe, false);
        _serverSubs[push.channel] = ServerSubscription.from(push.channel,
            subscribe.recoverable, subscribe.offset, subscribe.epoch);
        _serverSubscribeController.add(event);
        break;
      case Push_PushType.UNSUBSCRIBE:
        final subscription = _subscriptions[push.channel];
        if (subscription != null) {
          final event = UnsubscribeEvent();
          subscription.addUnsubscribe(event);
          break;
        }
        final serverSubscription = _serverSubs[push.channel];
        if (serverSubscription != null) {
          final event = ServerUnsubscribeEvent.from(push.channel);
          _serverSubs.remove(push.channel);
          _serverUnsubscribeController.add(event);
        }
        break;
    }
  }

  Future<String?> getToken(String channel) async {
    if (_clientID != null && _isPrivateChannel(channel)) {
      final event = PrivateSubEvent(_clientID!, channel);
      return _onPrivateSub(event);
    }
    return null;
  }

  Future<String> _onPrivateSub(PrivateSubEvent event) =>
      _config.onPrivateSub(event);

  bool _isPrivateChannel(String channel) =>
      channel.startsWith(_config.privateChannelPrefix);
}

enum _ClientState { connected, disconnected, connecting }
