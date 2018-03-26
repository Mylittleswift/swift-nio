//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//
//  HTTPServerPipelineHandler.swift
//  NIOHTTP1
//
//  Created by Cory Benfield on 01/03/2018.
//

import NIO

/// A `ChannelHandler` that handles HTTP pipelining by buffering inbound data until a
/// response has been sent.
///
/// This handler ensures that HTTP server pipelines only process one request at a time.
/// This is the safest way for pipelining-unaware code to operate, as it ensures that
/// mutation of any shared server state is not parallelised, and that responses are always
/// sent for each request in turn. In almost all cases this is the behaviour that a
/// pipeline will want. This is achieved without doing too much buffering by preventing
/// the `Channel` from reading from the socket until a complete response is processed,
/// ensuring that a malicious client is not capable of overwhelming a server by shoving
/// an enormous amount of data down the `Channel` while a server is processing a
/// slow response.
///
/// See [RFC 7320 Section 6.3.2](https://tools.ietf.org/html/rfc7230#section-6.3.2) for
/// more details on safely handling HTTP pipelining.
///
/// In addition to handling the request buffering, this `ChannelHandler` is aware of
/// TCP half-close. While there are very few HTTP clients that are capable of TCP
/// half-close, clients that are not HTTP specific (e.g. `netcat`) may trigger a TCP
/// half-close. Having this `ChannelHandler` be aware of TCP half-close makes it easier
/// to build HTTP servers that are resilient to this kind of behaviour.
///
/// The TCP half-close handling is done by buffering the half-close notification along
/// with the HTTP request parts. The half-close notification will be delivered in order
/// with the rest of the reads. If the half-close occurs either before a request is received
/// or during a request body upload, it will be delivered immediately. If a half-close is
/// received immediately after `HTTPServerRequestPart.end`, it will also be passed along
/// immediately, allowing this signal to be seen by the HTTP server as early as possible.
public final class HTTPServerPipelineHandler: ChannelDuplexHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias InboundOut = HTTPServerRequestPart
    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = HTTPServerResponsePart

    public init() { }

    /// The state of the HTTP connection.
    private enum ConnectionState {
        /// We are waiting for a HTTP response to complete before we
        /// let the next request in.
        case responseEndPending

        /// Neither a request nor a response are complete. This can be either
        /// because nothing is happening on the connection, or because the request
        /// and response are simultaneously progressing and have not completed.
        case idle

        /// The server has responded early, before the request has completed. We need
        /// to wait for the request to complete, but won't block anything.
        case requestEndPending

        mutating func responseEndReceived() {
            switch self {
            case .responseEndPending:
                // Got the response we were waiting for.
                self = .idle
            case .idle:
                // We got a response while still receiving a request, which we have to
                // wait for.
                self = .requestEndPending
            case .requestEndPending:
                preconditionFailure("Received second response")
            }
        }

        mutating func requestEndReceived() {
            switch self {
            case .requestEndPending:
                // Got the request end we were waiting for.
                self = .idle
            case .idle:
                // We got a request and the response isn't done, wait for the
                // response.
                self = .responseEndPending
            case .responseEndPending:
                preconditionFailure("Received second request")
            }
        }
    }

    /// The events that this handler buffers while waiting for the server to
    /// generate a response.
    private enum BufferedEvent {
        /// A channelRead event.
        case channelRead(NIOAny)

        /// A TCP half-close. This is buffered to ensure that subsequent channel
        /// handlers that are aware of TCP half-close are informed about it in
        /// the appropriate order.
        case halfClose
    }

    /// The connection state
    private var state = ConnectionState.idle

    /// While we're waiting to send the response we don't read from the socket.
    /// This keeps track of whether we need to call read() when we've send our response.
    private var readPending = false

    /// The buffered HTTP requests that are not going to be addressed yet. In general clients
    /// don't pipeline, so this initially allocates no space for data at all. Clients that
    /// do pipeline will cause dynamic resizing of the buffer, which is generally acceptable.
    private var eventBuffer = CircularBuffer<BufferedEvent>(initialRingCapacity: 0)

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        if case .responseEndPending = self.state {
            self.eventBuffer.append(.channelRead(data))
            return
        }

        if case .end = self.unwrapInboundIn(data) {
            // New request is complete. We don't want any more data from now on.
            self.state.requestEndReceived()
        }
        ctx.fireChannelRead(data)
    }

    public func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        switch event {
        case let evt as ChannelEvent where evt == ChannelEvent.inputClosed:
            // We only buffer half-close if there are request parts we're waiting to send.
            // Otherwise we deliver the half-close immediately.
            if case .responseEndPending = self.state, self.eventBuffer.count > 0 {
                self.eventBuffer.append(.halfClose)
            } else {
                ctx.fireUserInboundEventTriggered(event)
            }
        default:
            ctx.fireUserInboundEventTriggered(event)
        }
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        assert(self.state != .requestEndPending,
               "Received second response while waiting for first one to complete")
        var startReadingAgain = false
        if case .end = self.unwrapOutboundIn(data) {
            startReadingAgain = true
        }

        ctx.write(data, promise: promise)

        if startReadingAgain {
            self.state.responseEndReceived()
            self.deliverPendingRequests(ctx: ctx)
            self.startReading(ctx: ctx)
        }
    }

    public func read(ctx: ChannelHandlerContext) {
        if case .responseEndPending = self.state {
            self.readPending = true
        } else {
            ctx.read()
        }
    }

    /// A response has been sent: we can now start passing reads through
    /// again if there are no further pending requests, and send any read()
    /// call we may have swallowed.
    private func startReading(ctx: ChannelHandlerContext) {
        if self.readPending && self.state != .responseEndPending {
            self.readPending = false
            ctx.read()
        }
    }

    /// A response has been sent: deliver all pending requests and
    /// mark the channel ready to handle more requests.
    private func deliverPendingRequests(ctx: ChannelHandlerContext) {
        var deliveredRead = false

        while self.state != .responseEndPending, let event = self.eventBuffer.first {
            _ = self.eventBuffer.removeFirst()

            switch event {
            case .channelRead(let read):
                self.channelRead(ctx: ctx, data: read)
                deliveredRead = true
            case .halfClose:
                // When we fire the half-close, we want to forget all prior reads.
                // They will just trigger further half-close notifications we don't
                // need.
                self.readPending = false
                ctx.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            }
        }

        if deliveredRead {
            ctx.fireChannelReadComplete()
        }

        // We need to quickly check whether there is an EOF waiting here, because
        // if there is we should also unbuffer it and pass it along. There is no
        // advantage in sitting on it, and it may help the later channel handlers
        // be more sensible about keep-alive logic if they can see this early.
        // This is done after `fireChannelReadComplete` to keep the same observable
        // behaviour as `SocketChannel`, which fires these events in this order.
        if case .some(.halfClose) = self.eventBuffer.first {
            _ = self.eventBuffer.removeFirst()
            self.readPending = false
            ctx.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        }
    }
}
