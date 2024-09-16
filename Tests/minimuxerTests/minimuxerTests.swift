//
//  Test.swift
//  minimuxer
//
//  Created by Joseph Mattiello on 9/16/24.
//

import Testing
@testable import minimuxer
@testable import libminimuxer

struct Test {

    @Test func test_minimuxer() async throws {

        let ready = minimuxer.ready()
        #expect(ready)
    }
}
