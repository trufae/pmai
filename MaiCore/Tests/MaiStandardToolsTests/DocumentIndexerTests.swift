import XCTest

@testable import MaiStandardTools

final class DocumentIndexerTests: XCTestCase {
  private typealias DocumentIndexer = MaiDocumentIndexer
  func testCFunctions() {
    let source = """
      #include <stdio.h>

      static int helper(int a, int b) {
        return a + b;
      }

      int main(int argc, char **argv)
      {
        if (argc > 1) {
          printf("%d\\n", helper(argc, 2));
        }
        return 0;
      }
      """
    XCTAssertEqual(
      DocumentIndexer.sourceIndex(text: source, fileExtension: "c"),
      [
        DocumentIndexer.Entry(line: 3, title: "helper"),
        DocumentIndexer.Entry(line: 7, title: "main"),
      ])
  }

  func testPythonDefsAndClasses() {
    let source = """
      import os

      class Greeter:
          def __init__(self, name):
              self.name = name

          async def greet(self):
              return self.name

      def main():
          pass
      """
    XCTAssertEqual(
      DocumentIndexer.sourceIndex(text: source, fileExtension: "py"),
      [
        DocumentIndexer.Entry(line: 3, title: "class Greeter"),
        DocumentIndexer.Entry(line: 4, title: "__init__"),
        DocumentIndexer.Entry(line: 7, title: "greet"),
        DocumentIndexer.Entry(line: 10, title: "main"),
      ])
  }

  func testSwiftDeclarations() {
    let source = """
      import Foundation

      struct Point {
        let x: Int

        func scaled(by factor: Int) -> Point {
          Point(x: x * factor)
        }
      }

      @MainActor
      final class Store: ObservableObject {
        public static func shared() -> Store { Store() }
      }
      """
    XCTAssertEqual(
      DocumentIndexer.sourceIndex(text: source, fileExtension: "swift"),
      [
        DocumentIndexer.Entry(line: 3, title: "struct Point"),
        DocumentIndexer.Entry(line: 6, title: "scaled"),
        DocumentIndexer.Entry(line: 12, title: "class Store"),
        DocumentIndexer.Entry(line: 13, title: "shared"),
      ])
  }

  func testJavaScriptFunctions() {
    let source = """
      import fs from "fs";

      export function parse(input) {
        return input.trim();
      }

      const render = async (state) => {
        return state;
      };

      class Widget {
        draw() {
        }
      }
      """
    XCTAssertEqual(
      DocumentIndexer.sourceIndex(text: source, fileExtension: "js"),
      [
        DocumentIndexer.Entry(line: 3, title: "parse"),
        DocumentIndexer.Entry(line: 7, title: "render"),
        DocumentIndexer.Entry(line: 11, title: "class Widget"),
        DocumentIndexer.Entry(line: 12, title: "draw"),
      ])
  }

  func testShellFunctions() {
    let source = """
      #!/bin/sh
      set -e

      build() {
        make
      }

      function deploy {
        echo done
      }
      """
    XCTAssertEqual(
      DocumentIndexer.sourceIndex(text: source, fileExtension: "sh"),
      [
        DocumentIndexer.Entry(line: 4, title: "build"),
        DocumentIndexer.Entry(line: 8, title: "deploy"),
      ])
  }

  func testGoAndRustDeclarations() {
    let go = """
      package main

      type Server struct {
      }

      func (s *Server) Run() error {
        return nil
      }

      func main() {
      }
      """
    XCTAssertEqual(
      DocumentIndexer.sourceIndex(text: go, fileExtension: "go"),
      [
        DocumentIndexer.Entry(line: 3, title: "type Server"),
        DocumentIndexer.Entry(line: 6, title: "Run"),
        DocumentIndexer.Entry(line: 10, title: "main"),
      ])

    let rust = """
      pub struct Config {
      }

      impl Config {
          pub fn load(path: &str) -> Self {
              Self {}
          }
      }
      """
    XCTAssertEqual(
      DocumentIndexer.sourceIndex(text: rust, fileExtension: "rs"),
      [
        DocumentIndexer.Entry(line: 1, title: "struct Config"),
        DocumentIndexer.Entry(line: 4, title: "impl Config"),
        DocumentIndexer.Entry(line: 5, title: "load"),
      ])
  }

  func testMarkdownHeadingsSkipCodeFences() {
    let source = """
      # Title

      Intro text.

      ```sh
      # not a heading
      ```

      ## Usage

      ### Flags
      #missing space is not a heading
      """
    XCTAssertEqual(
      DocumentIndexer.markdownIndex(text: source),
      [
        DocumentIndexer.Entry(line: 1, title: "# Title"),
        DocumentIndexer.Entry(line: 9, title: "## Usage"),
        DocumentIndexer.Entry(line: 11, title: "### Flags"),
      ])
  }

  func testUnknownExtensionReturnsNil() {
    XCTAssertNil(DocumentIndexer.sourceIndex(text: "def x():", fileExtension: "md"))
    XCTAssertNil(DocumentIndexer.sourceIndex(text: "def x():", fileExtension: ""))
  }
}
