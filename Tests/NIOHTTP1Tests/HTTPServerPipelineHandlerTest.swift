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
//  HTTPServerPipelineHandlerTest.swift
//  NIOHTTP1Tests
//
//  Created by Cory Benfield on 02/03/2018.
//

import XCTest
import NIO
import NIOHTTP1

private final class ReadRecorder: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart

    enum Event: Equatable {
        case channelRead(InboundIn)
        case halfClose

        static func ==(lhs: Event, rhs: Event) -> Bool {
            switch (lhs, rhs) {
            case (.channelRead(let b1), .channelRead(let b2)):
                return b1 == b2
            case (.halfClose, .halfClose):
                return true
            default:
                return false
            }
        }
    }

    public var reads: [Event] = []

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        self.reads.append(.channelRead(self.unwrapInboundIn(data)))
    }

    func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        switch event {
        case let evt as ChannelEvent where evt == ChannelEvent.inputClosed:
            self.reads.append(.halfClose)
        default:
            ctx.fireUserInboundEventTriggered(event)
        }
    }
}

private final class ReadCountingHandler: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    public var readCount = 0

    func read(ctx: ChannelHandlerContext) {
        self.readCount += 1
        ctx.read()
    }
}


class HTTPServerPipelineHandlerTest: XCTestCase {
    var channel: EmbeddedChannel! = nil
    var requestHead: HTTPRequestHead! = nil
    var responseHead: HTTPResponseHead! = nil
    fileprivate var readRecorder: ReadRecorder! = nil
    fileprivate var readCounter: ReadCountingHandler! = nil

    override func setUp() {
        self.channel = EmbeddedChannel()
        self.readRecorder = ReadRecorder()
        self.readCounter = ReadCountingHandler()
        XCTAssertNoThrow(try channel.pipeline.add(handler: self.readCounter).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPResponseEncoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: HTTPServerPipelineHandler()).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: self.readRecorder).wait())

        self.requestHead = HTTPRequestHead(version: .init(major: 1, minor: 1), method: .GET, uri: "/path")
        self.requestHead.headers.add(name: "Host", value: "example.com")

        self.responseHead = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok)
        self.responseHead.headers.add(name: "Server", value: "SwiftNIO")
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.channel.finish())
        self.requestHead = nil
        self.responseHead = nil
        self.readCounter = nil
        self.readRecorder = nil
        self.channel = nil
    }

    func testBasicBufferingBehaviour() throws {
        // Send in 3 requests at once.
        for _ in 0..<3 {
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // Only one request should have made it through.
        XCTAssertEqual(self.readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Unblock by sending a response.
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.head(self.responseHead)).wait())
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.end(nil)).wait())

        // Two requests should have made it through now.
        XCTAssertEqual(self.readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Now send the last response.
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.head(self.responseHead)).wait())
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.end(nil)).wait())

        // Now all three.
        XCTAssertEqual(self.readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])
    }

    func testReadCallsAreSuppressedWhenPipelining() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send in a request.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Call read again, twice. This should not change the number.
        self.channel.read()
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send a response.
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.head(self.responseHead)).wait())
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.end(nil)).wait())

        // This should have automatically triggered a call to read(), but only one.
        XCTAssertEqual(self.readCounter.readCount, 2)
    }

    func testReadCallsAreSuppressedWhenUnbufferingIfThereIsStillBufferedData() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send in two requests.
        for _ in 0..<2 {
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // Call read again, twice. This should not change the number.
        self.channel.read()
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send a response.
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.head(self.responseHead)).wait())
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.end(nil)).wait())

        // This should have not triggered a call to read.
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Try calling read some more.
        self.channel.read()
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Now send in the last response, and see the read go through.
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.head(self.responseHead)).wait())
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.end(nil)).wait())
        XCTAssertEqual(self.readCounter.readCount, 2)
    }

    func testServerCanRespondEarly() throws {
        // Send in the first part of a request.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))

        // This is still moving forward: we can read.
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Now the server sends a response immediately.
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.head(self.responseHead)).wait())
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.end(nil)).wait())

        // We're still moving forward and can read.
        XCTAssertEqual(self.readCounter.readCount, 1)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 2)

        // The client response completes.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // We can still read.
        XCTAssertEqual(self.readCounter.readCount, 2)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 3)
    }

    func testPipelineHandlerWillBufferHalfClose() throws {
        // Send in 2 requests at once.
        for _ in 0..<3 {
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // Now half-close the connection.
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // Only one request should have made it through, no half-closure yet.
        XCTAssertEqual(self.readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Unblock by sending a response.
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.head(self.responseHead)).wait())
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.end(nil)).wait())

        // Two requests should have made it through now.
        XCTAssertEqual(self.readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Now send the last response.
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.head(self.responseHead)).wait())
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.end(nil)).wait())

        // Now the half-closure should be delivered.
        XCTAssertEqual(self.readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .halfClose])
    }

    func testPipelineHandlerWillDeliverHalfCloseEarly() throws {
        // Send in a request.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Now send a new request but half-close the connection before we get .end.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // Only one request should have made it through, no half-closure yet.
        XCTAssertEqual(self.readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Unblock by sending a response.
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.head(self.responseHead)).wait())
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.end(nil)).wait())

        // The second request head, followed by the half-close, should have made it through.
        XCTAssertEqual(self.readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .halfClose])
    }

    func testAReadIsNotIssuedWhenUnbufferingAHalfCloseAfterRequestComplete() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send in two requests and then half-close.
        for _ in 0..<2 {
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // Call read again, twice. This should not change the number.
        self.channel.read()
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send a response.
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.head(self.responseHead)).wait())
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.end(nil)).wait())

        // This should have not triggered a call to read.
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Now send in the last response. This should also not issue a read.
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.head(self.responseHead)).wait())
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.end(nil)).wait())
        XCTAssertEqual(self.readCounter.readCount, 1)
    }

    func testHalfCloseWhileWaitingForResponseIsPassedAlongIfNothingElseBuffered() throws {
        // Send in 2 requests at once.
        for _ in 0..<2 {
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // Only one request should have made it through, no half-closure yet.
        XCTAssertEqual(self.readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Unblock by sending a response.
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.head(self.responseHead)).wait())
        XCTAssertNoThrow(try channel.write(HTTPServerResponsePart.end(nil)).wait())

        // Two requests should have made it through now. Still no half-closure.
        XCTAssertEqual(self.readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Now send the half-closure.
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // The half-closure should be delivered immediately.
        XCTAssertEqual(self.readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .halfClose])
    }
}
