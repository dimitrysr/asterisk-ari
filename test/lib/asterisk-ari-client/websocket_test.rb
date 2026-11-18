require_relative '../../test_helper'
require 'socket'
require 'timeout'
require 'minitest/mock'

class TestWebsocket < Minitest::Test
  def setup
    @server = TCPServer.new('127.0.0.1', 0)
    @client = Ari::Client.new(
      url: "http://127.0.0.1:#{@server.addr[1]}/ari",
      api_key: 'asterisk:asterisk',
      app: 'dialplan'
    )
  end

  def teardown
    @client.ws&.close
    @server.close
  end

  # Answers the upgrade request like Asterisk; returns the server end of the websocket and the request.
  def accept_websocket
    socket = @server.accept
    handshake = WebSocket::Handshake::Server.new
    request = +''
    until handshake.finished?
      chunk = socket.readpartial(4096)
      request << chunk
      handshake << chunk
    end
    @protocol_version = handshake.version
    socket.write handshake.to_s
    [socket, request]
  end

  def text_frame(data)
    WebSocket::Frame::Outgoing::Server.new(version: @protocol_version, data: data, type: :text).to_s
  end

  def test_connect_opens_the_events_websocket_and_passes_events_on
    opened = Queue.new
    calls = Queue.new
    @client.on(:websocket_open) { opened << true }
    @client.on(:stasis_start) { |event| calls << event.args }
    server = Thread.new { accept_websocket }
    @client.connect_websocket
    socket, request = server.value

    assert opened.pop(timeout: 5)
    assert @client.ws.open?
    assert_equal 'GET /ari/events?api_key=asterisk%3Aasterisk&app=dialplan HTTP/1.1', request.lines.first.chomp

    socket.write text_frame(MultiJson.dump(type: 'StasisStart', args: ['in'], channel: { id: '1794990944.1' }))
    assert_equal ['in'], calls.pop(timeout: 5)
  end

  def test_reconnect_closes_the_previous_websocket_quietly
    closed = false
    opened = Queue.new
    @client.on(:websocket_close) { closed = true }
    @client.on(:websocket_open) { opened << true }
    server = Thread.new { accept_websocket }
    @client.connect_websocket
    previous, = server.value
    assert opened.pop(timeout: 5)

    server = Thread.new { accept_websocket }
    @client.connect_websocket
    server.value
    Timeout.timeout(5) { previous.read }

    assert opened.pop(timeout: 5)
    assert @client.ws.open?
    refute closed
  end

  # websocket-client-simple starts its reader thread before it writes the upgrade request.
  def test_failed_connect_closes_what_it_opened
    closed = false
    @client.on(:websocket_close) { closed = true }
    handshake = Object.new
    def handshake.to_s
      raise Errno::EPIPE
    end
    threads = Thread.list

    WebSocket::Handshake::Client.stub(:new, handshake) do
      assert_raises(Errno::EPIPE) { @client.connect_websocket }
    end
    accepted = @server.accept

    assert_nil @client.ws
    refute closed, 'a failed attempt reports a closed websocket'
    assert accepted.wait_readable(5), 'the socket of the failed attempt stays open'
    assert_nil accepted.read(1)
    (Thread.list - threads).each { |thread| thread.join(5) }
    assert_empty((Thread.list - threads).select(&:alive?))
  end

  def test_failed_reconnect_keeps_the_closed_previous_websocket
    opened = Queue.new
    @client.on(:websocket_open) { opened << true }
    server = Thread.new { accept_websocket }
    @client.connect_websocket
    server.value
    assert opened.pop(timeout: 5)
    previous = @client.ws
    @server.close

    assert_raises(Errno::ECONNREFUSED) { @client.connect_websocket }

    assert_same previous, @client.ws
    assert previous.closed?
    @server = TCPServer.new('127.0.0.1', 0)
  end
end
