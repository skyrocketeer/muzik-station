import LocalWaveData
import LocalWaveCore
import LocalWaveDomain
//
//  Tests.swift
//  musicappTests
//
//  Created by Oleg Pustovit on 10.01.2025.
//

import Testing

import Foundation
@testable import localwave

struct FileHelperTests {
    @Test func importedFileNameSurvivesSameNameCollision() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = temporaryRoot.appendingPathComponent("Sources", isDirectory: true)
        let destinationDirectory = temporaryRoot.appendingPathComponent("Added Files", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let fileName = "Track-\(UUID().uuidString).mp4"
        let firstSourceDirectory = sourceDirectory.appendingPathComponent("first", isDirectory: true)
        let secondSourceDirectory = sourceDirectory.appendingPathComponent("second", isDirectory: true)
        try fileManager.createDirectory(at: firstSourceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: secondSourceDirectory, withIntermediateDirectories: true)
        let firstSource = firstSourceDirectory.appendingPathComponent(fileName)
        let secondSource = secondSourceDirectory.appendingPathComponent(fileName)
        try Data("first video".utf8).write(to: firstSource)
        try Data("second video".utf8).write(to: secondSource)

        let firstCopy = try DependencyContainer.copyAudio([firstSource], destinationDirectory: destinationDirectory).files[0]
        let secondCopy = try DependencyContainer.copyAudio([secondSource], destinationDirectory: destinationDirectory).files[0]
        let repeatedCopy = try DependencyContainer.copyAudio([secondSource], destinationDirectory: destinationDirectory).files[0]
        let identicalSource = secondSourceDirectory.appendingPathComponent("renamed-copy.mp4")
        try Data("second video".utf8).write(to: identicalSource)
        let identicalCopy = try DependencyContainer.copyAudio([identicalSource], destinationDirectory: destinationDirectory).files[0]

        #expect(firstCopy.lastPathComponent == fileName)
        #expect(secondCopy.lastPathComponent == fileName)
        #expect(firstCopy != secondCopy)
        #expect(secondCopy == repeatedCopy)
        #expect(identicalCopy == secondCopy)
    }
    @Test func testToString() async throws {
        let url = URL(fileURLWithPath: "/Users/doggyman/Documents/myFile.txt")
        let helper = FileHelper(fileURL: url)
        #expect(helper.toString() == "file:///Users/doggyman/Documents/myFile.txt")
    }

    @Test func testName() async throws {
        let url = URL(fileURLWithPath: "/Users/doggyman/Documents/myFile.txt")
        let helper = FileHelper(fileURL: url)
        #expect(helper.name() == "myFile.txt")
    }

    @Test func testParent() async throws {
        let url = URL(fileURLWithPath: "/Users/doggyman/Documents/myFile.txt")
        let helper = FileHelper(fileURL: url)
        #expect(helper.parent()?.path == "/Users/doggyman/Documents")
    }

    @Test func testRelativePath() async throws {
        let baseURL = URL(fileURLWithPath: "/Users/doggyman/Documents")
        let fileURL = URL(fileURLWithPath: "/Users/doggyman/Documents/Folder/myFile.txt")
        let helper = FileHelper(fileURL: fileURL)
        #expect(helper.relativePath(from: baseURL) == "Folder/myFile.txt")
    }

    @Test func relativePathSamePath() async throws {
        let baseURL = URL(fileURLWithPath: "/Users/doggyman/Documents/Folder/myFile.txt")
        let fileURL = URL(fileURLWithPath: "/Users/doggyman/Documents/Folder/myFile.txt")
        let helper = FileHelper(fileURL: fileURL)
        #expect(helper.relativePath(from: baseURL) == "")
    }

    @Test func createURLWithEmptyRelativePath() async throws {
        let baseURL = URL(fileURLWithPath: "/Users/doggyman/Documents")
        let relativePath = ""
        let expectedURL = URL(fileURLWithPath: "/Users/doggyman/Documents")
        let createdURL = FileHelper.createURL(baseURL: baseURL, relativePath: relativePath)
        #expect(createdURL?.path == expectedURL.path)
    }

    @Test func testCreateURL() async throws {
        let baseURL = URL(fileURLWithPath: "/Users/doggyman/Documents")
        let relativePath = "Folder/myFile.txt"
        let expectedURL = URL(fileURLWithPath: "/Users/doggyman/Documents/Folder/myFile.txt")
        let createdURL = FileHelper.createURL(baseURL: baseURL, relativePath: relativePath)
        #expect(createdURL?.path == expectedURL.path)
    }
}
