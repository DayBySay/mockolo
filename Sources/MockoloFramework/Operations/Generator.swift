//
//  Copyright (c) 2018. Uber Technologies
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation

enum InputError: Error {
    case annotationError
    case sourceFilesError
}

/// Performs end to end mock generation flow
public func generate(sourceDirs: [String]?,
                     sourceFiles: [String]?,
                     parser: SourceParsing,
                     exclusionSuffixes: [String],
                     mockFilePaths: [String]?,
                     annotation: String,
                     header: String?,
                     macro: String?,
                     declType: DeclType,
                     useTemplateFunc: Bool,
                     useMockObservable: Bool,
                     enableFuncArgsHistory: Bool,
                     testableImports: [String]?,
                     customImports: [String]?,
                     excludeImports: [String]?,
                     to outputFilePath: String,
                     loggingLevel: Int,
                     concurrencyLimit: Int?,
                     onCompletion: @escaping (String) -> ()) throws {
    guard sourceDirs != nil || sourceFiles != nil else {
        log("Source files or directories do not exist", level: .error)
        throw InputError.sourceFilesError
    }
    
    scanConcurrencyLimit = concurrencyLimit
    minLogLevel = loggingLevel
    var candidates = [(String, Int64)]()
    var resolvedEntities = [ResolvedEntity]()
    var parentMocks = [String: Entity]()
    var protocolMap = [String: Entity]() // 引数として渡されたsrcにある全てのプロトコルが入る
    var annotatedProtocolMap = [String: Entity]() // ↑の中からアノテーションされているプロトコルが入る
    var pathToContentMap = [(String, Data, Int64)]()
    var pathToImportsMap = ImportMap()

    signpost_begin(name: "Process input")
    let t0 = CFAbsoluteTimeGetCurrent()
    log("Process input mock files...", level: .info)
    if let mockFilePaths = mockFilePaths, !mockFilePaths.isEmpty {
        parser.parseProcessedDecls(mockFilePaths, fileMacro: macro) { (elements, imports) in
                                    elements.forEach { element in
                                        parentMocks[element.entityNode.name] = element
                                    }
                                    
                                    if let imports = imports {
                                        for (path, importMap) in imports {
                                            pathToImportsMap[path] = importMap
                                        }
                                    }
        }
    }
    signpost_end(name: "Process input")
    let t1 = CFAbsoluteTimeGetCurrent()
    log("Took", t1-t0, level: .verbose)
    
    signpost_begin(name: "Generate protocol map")
    log("Process source files and generate an annotated/protocol map...", level: .info)
    let paths = sourceDirs ?? sourceFiles
    let isDirs = sourceDirs != nil
    // protocolMap annotatedProtocolMap pathToImportsMap にMock生成に必要な情報を詰める
    parser.parseDecls(paths,
                      isDirs: isDirs,
                      exclusionSuffixes: exclusionSuffixes,
                      annotation: annotation,
                      fileMacro: macro,
                      declType: declType) { (elements, imports) in // elemtnsはEntity（メタデータ）のリスト importsはimportしているライブラリとか
                        elements.forEach { element in
                            protocolMap[element.entityNode.name] = element
                            if element.isAnnotated {
                                annotatedProtocolMap[element.entityNode.name] = element
                            }
                        }
                        if let imports = imports {
                            for (path, importMap) in imports {
                                pathToImportsMap[path] = importMap
                            }
                        }
    }
    signpost_end(name: "Generate protocol map")
    let t2 = CFAbsoluteTimeGetCurrent()
    log("Took", t2-t1, level: .verbose)
    
    let typeKeyList = [parentMocks.compactMap {$0.key.components(separatedBy: "Mock").first}, annotatedProtocolMap.map {$0.key}].flatMap{$0}
    var typeKeys = [String: String]()
    typeKeyList.forEach { (t: String) in
        typeKeys[t] = "\(t)Mock()"
    }
    Type.customTypeMap = typeKeys

    signpost_begin(name: "Generate models")
    log("Resolve inheritance and generate unique entity models...", level: .info)
    // Parseした情報からモデルを生成する
    generateUniqueModels(protocolMap: protocolMap,
                         annotatedProtocolMap: annotatedProtocolMap,
                         inheritanceMap: parentMocks,
                         completion: { container in
                            pathToContentMap.append(contentsOf: container.imports)
                            resolvedEntities.append(container.entity)
    })
    signpost_end(name: "Generate models")
    let t3 = CFAbsoluteTimeGetCurrent()
    log("Took", t3-t2, level: .verbose)
    
    signpost_begin(name: "Render models")
    log("Render models with templates...", level: .info)
    renderTemplates(entities: resolvedEntities,
                    useTemplateFunc: useTemplateFunc,
                    useMockObservable: useMockObservable,
                    enableFuncArgsHistory: enableFuncArgsHistory) { (mockString: String, offset: Int64) in // mockStringは生成された各クラスのMock文字列が返ってくる
                        candidates.append((mockString, offset))
    }
    signpost_end(name: "Render models")
    let t4 = CFAbsoluteTimeGetCurrent()
    log("Took", t4-t3, level: .verbose)
     
    signpost_begin(name: "Write results")
    log("Write the mock results and import lines to", outputFilePath, level: .info)

    let imports = handleImports(pathToImportsMap: pathToImportsMap,
                                pathToContentMap: pathToContentMap,
                                customImports: customImports,
                                excludeImports: excludeImports,
                                testableImports: testableImports)

    // 生成したMock用の情報をまとまった文字列にして出力する
    let result = write(candidates: candidates,
                       header: header,
                       macro: macro,
                       imports: imports,
                       to: outputFilePath)
    signpost_end(name: "Write results")
    let t5 = CFAbsoluteTimeGetCurrent()
    log("Took", t5-t4, level: .verbose)
    
    let count = result.components(separatedBy: "\n").count
    log("TOTAL", t5-t0, level: .verbose)
    log("#Protocols = \(protocolMap.count), #Annotated protocols = \(annotatedProtocolMap.count), #Parent mock classes = \(parentMocks.count), #Final mock classes = \(candidates.count), File LoC = \(count)", level: .verbose)
    
    onCompletion(result)
}


/* EntityNodeをみるとこんなんが返ってくる
 (lldb) po element.entityNode
 ▿ SwiftSyntax.ProtocolDeclSyntax
   - attributes : nil
   - modifiers : nil
   ▿ protocolKeyword : SwiftSyntax.TokenSyntax
     - text : "protocol"
     ▿ leadingTrivia : Trivia
       ▿ pieces : 3 elements
         ▿ 0 : TriviaPiece
           - newlines : 2
         ▿ 1 : TriviaPiece
           - docLineComment : "/// @mockable(rx: segments = BehaviorSubject)"
         ▿ 2 : TriviaPiece
           - newlines : 1
     ▿ trailingTrivia : Trivia
       ▿ pieces : 1 element
         ▿ 0 : TriviaPiece
           - spaces : 1
     - tokenKind : SwiftSyntax.TokenKind.protocolKeyword
   ▿ identifier : SwiftSyntax.TokenSyntax
     - text : "AnnouncementListUseCase"
     ▿ leadingTrivia : Trivia
       - pieces : 0 elements
     ▿ trailingTrivia : Trivia
       ▿ pieces : 1 element
         ▿ 0 : TriviaPiece
           - spaces : 1
     ▿ tokenKind : TokenKind
       - identifier : "AnnouncementListUseCase"
   - inheritanceClause : nil
   - genericWhereClause : nil
   ▿ members : SwiftSyntax.MemberDeclBlockSyntax
     ▿ leftBrace : SwiftSyntax.TokenSyntax
       - text : "{"
       ▿ leadingTrivia : Trivia
         - pieces : 0 elements
       ▿ trailingTrivia : Trivia
         - pieces : 0 elements
       - tokenKind : SwiftSyntax.TokenKind.leftBrace
     ▿ members : SwiftSyntax.MemberDeclListSyntax
       ▿ 0 : SwiftSyntax.MemberDeclListItemSyntax
         ▿ decl : SwiftSyntax.VariableDeclSyntax
           - attributes : nil
           - modifiers : nil
           ▿ letOrVarKeyword : SwiftSyntax.TokenSyntax
             - text : "var"
             ▿ leadingTrivia : Trivia
               ▿ pieces : 2 elements
                 ▿ 0 : TriviaPiece
                   - newlines : 1
                 ▿ 1 : TriviaPiece
                   - spaces : 4
             ▿ trailingTrivia : Trivia
               ▿ pieces : 1 element
                 ▿ 0 : TriviaPiece
                   - spaces : 1
             - tokenKind : SwiftSyntax.TokenKind.varKeyword
           ▿ bindings : SwiftSyntax.PatternBindingListSyntax
             ▿ 0 : SwiftSyntax.PatternBindingSyntax
               ▿ pattern : SwiftSyntax.IdentifierPatternSyntax
                 ▿ identifier : SwiftSyntax.TokenSyntax
                   - text : "category"
                   ▿ leadingTrivia : Trivia
                     - pieces : 0 elements
                   ▿ trailingTrivia : Trivia
                     - pieces : 0 elements
                   ▿ tokenKind : TokenKind
                     - identifier : "category"
               ▿ typeAnnotation : Optional<SyntaxProtocol>
                 ▿ some : SwiftSyntax.TypeAnnotationSyntax
                   ▿ colon : SwiftSyntax.TokenSyntax
                     - text : ":"
                     ▿ leadingTrivia : Trivia
                       - pieces : 0 elements
                     ▿ trailingTrivia : Trivia
                       ▿ pieces : 1 element
                         ▿ 0 : TriviaPiece
                           - spaces : 1
                     - tokenKind : SwiftSyntax.TokenKind.colon
                   ▿ type : SwiftSyntax.MemberTypeIdentifierSyntax
                     ▿ baseType : SwiftSyntax.SimpleTypeIdentifierSyntax
                       ▿ name : SwiftSyntax.TokenSyntax
                         - text : "AnnouncementContent"
                         ▿ leadingTrivia : Trivia
                           - pieces : 0 elements
                         ▿ trailingTrivia : Trivia
                           - pieces : 0 elements
                         ▿ tokenKind : TokenKind
                           - identifier : "AnnouncementContent"
                       - genericArgumentClause : nil
                     ▿ period : SwiftSyntax.TokenSyntax
                       - text : "."
                       ▿ leadingTrivia : Trivia
                         - pieces : 0 elements
                       ▿ trailingTrivia : Trivia
                         - pieces : 0 elements
                       - tokenKind : SwiftSyntax.TokenKind.period
                     ▿ name : SwiftSyntax.TokenSyntax
                       - text : "Category"
                       ▿ leadingTrivia : Trivia
                         - pieces : 0 elements
                       ▿ trailingTrivia : Trivia
                         ▿ pieces : 1 element
                           ▿ 0 : TriviaPiece
                             - spaces : 1
                       ▿ tokenKind : TokenKind
                         - identifier : "Category"
                     - genericArgumentClause : nil
               - initializer : nil
               ▿ accessor : Optional<SyntaxProtocol>
                 ▿ some : SwiftSyntax.AccessorBlockSyntax
                   ▿ leftBrace : SwiftSyntax.TokenSyntax
                     - text : "{"
                     ▿ leadingTrivia : Trivia
                       - pieces : 0 elements
                     ▿ trailingTrivia : Trivia
                       ▿ pieces : 1 element
                         ▿ 0 : TriviaPiece
                           - spaces : 1
                     - tokenKind : SwiftSyntax.TokenKind.leftBrace
                   ▿ accessors : SwiftSyntax.AccessorListSyntax
                     ▿ 0 : SwiftSyntax.AccessorDeclSyntax
                       - attributes : nil
                       - modifier : nil
                       ▿ accessorKind : SwiftSyntax.TokenSyntax
                         - text : "get"
                         ▿ leadingTrivia : Trivia
                           - pieces : 0 elements
                         ▿ trailingTrivia : Trivia
                           ▿ pieces : 1 element
                             ▿ 0 : TriviaPiece
                               - spaces : 1
                         ▿ tokenKind : TokenKind
                           - contextualKeyword : "get"
                       - parameter : nil
                       - body : nil
                   ▿ rightBrace : SwiftSyntax.TokenSyntax
                     - text : "}"
                     ▿ leadingTrivia : Trivia
                       - pieces : 0 elements
                     ▿ trailingTrivia : Trivia
                       - pieces : 0 elements
                     - tokenKind : SwiftSyntax.TokenKind.rightBrace
               - trailingComma : nil
         - semicolon : nil
       ▿ 1 : SwiftSyntax.MemberDeclListItemSyntax
         ▿ decl : SwiftSyntax.VariableDeclSyntax
           - attributes : nil
           - modifiers : nil
           ▿ letOrVarKeyword : SwiftSyntax.TokenSyntax
             - text : "var"
             ▿ leadingTrivia : Trivia
               ▿ pieces : 2 elements
                 ▿ 0 : TriviaPiece
                   - newlines : 1
                 ▿ 1 : TriviaPiece
                   - spaces : 4
             ▿ trailingTrivia : Trivia
               ▿ pieces : 1 element
                 ▿ 0 : TriviaPiece
                   - spaces : 1
             - tokenKind : SwiftSyntax.TokenKind.varKeyword
           ▿ bindings : SwiftSyntax.PatternBindingListSyntax
             ▿ 0 : SwiftSyntax.PatternBindingSyntax
               ▿ pattern : SwiftSyntax.IdentifierPatternSyntax
                 ▿ identifier : SwiftSyntax.TokenSyntax
                   - text : "segments"
                   ▿ leadingTrivia : Trivia
                     - pieces : 0 elements
                   ▿ trailingTrivia : Trivia
                     - pieces : 0 elements
                   ▿ tokenKind : TokenKind
                     - identifier : "segments"
               ▿ typeAnnotation : Optional<SyntaxProtocol>
                 ▿ some : SwiftSyntax.TypeAnnotationSyntax
                   ▿ colon : SwiftSyntax.TokenSyntax
                     - text : ":"
                     ▿ leadingTrivia : Trivia
                       - pieces : 0 elements
                     ▿ trailingTrivia : Trivia
                       ▿ pieces : 1 element
                         ▿ 0 : TriviaPiece
                           - spaces : 1
                     - tokenKind : SwiftSyntax.TokenKind.colon
                   ▿ type : SwiftSyntax.SimpleTypeIdentifierSyntax
                     ▿ name : SwiftSyntax.TokenSyntax
                       - text : "Observable"
                       ▿ leadingTrivia : Trivia
                         - pieces : 0 elements
                       ▿ trailingTrivia : Trivia
                         - pieces : 0 elements
                       ▿ tokenKind : TokenKind
                         - identifier : "Observable"
                     ▿ genericArgumentClause : Optional<SyntaxProtocol>
                       ▿ some : SwiftSyntax.GenericArgumentClauseSyntax
                         ▿ leftAngleBracket : SwiftSyntax.TokenSyntax
                           - text : "<"
                           ▿ leadingTrivia : Trivia
                             - pieces : 0 elements
                           ▿ trailingTrivia : Trivia
                             - pieces : 0 elements
                           - tokenKind : SwiftSyntax.TokenKind.leftAngle
                         ▿ arguments : SwiftSyntax.GenericArgumentListSyntax
                           ▿ 0 : SwiftSyntax.GenericArgumentSyntax
                             ▿ argumentType : SwiftSyntax.ArrayTypeSyntax
                               ▿ leftSquareBracket : SwiftSyntax.TokenSyntax
                                 - text : "["
                                 ▿ leadingTrivia : Trivia
                                   - pieces : 0 elements
                                 ▿ trailingTrivia : Trivia
                                   - pieces : 0 elements
                                 - tokenKind : SwiftSyntax.TokenKind.leftSquareBracket
                               ▿ elementType : SwiftSyntax.SimpleTypeIdentifierSyntax
                                 ▿ name : SwiftSyntax.TokenSyntax
                                   - text : "AnnouncementSegment"
                                   ▿ leadingTrivia : Trivia
                                     - pieces : 0 elements
                                   ▿ trailingTrivia : Trivia
                                     - pieces : 0 elements
                                   ▿ tokenKind : TokenKind
                                     - identifier : "AnnouncementSegment"
                                 - genericArgumentClause : nil
                               ▿ rightSquareBracket : SwiftSyntax.TokenSyntax
                                 - text : "]"
                                 ▿ leadingTrivia : Trivia
                                   - pieces : 0 elements
                                 ▿ trailingTrivia : Trivia
                                   - pieces : 0 elements
                                 - tokenKind : SwiftSyntax.TokenKind.rightSquareBracket
                             - trailingComma : nil
                         ▿ rightAngleBracket : SwiftSyntax.TokenSyntax
                           - text : ">"
                           ▿ leadingTrivia : Trivia
                             - pieces : 0 elements
                           ▿ trailingTrivia : Trivia
                             ▿ pieces : 1 element
                               ▿ 0 : TriviaPiece
                                 - spaces : 1
                           - tokenKind : SwiftSyntax.TokenKind.rightAngle
               - initializer : nil
               ▿ accessor : Optional<SyntaxProtocol>
                 ▿ some : SwiftSyntax.AccessorBlockSyntax
                   ▿ leftBrace : SwiftSyntax.TokenSyntax
                     - text : "{"
                     ▿ leadingTrivia : Trivia
                       - pieces : 0 elements
                     ▿ trailingTrivia : Trivia
                       ▿ pieces : 1 element
                         ▿ 0 : TriviaPiece
                           - spaces : 1
                     - tokenKind : SwiftSyntax.TokenKind.leftBrace
                   ▿ accessors : SwiftSyntax.AccessorListSyntax
                     ▿ 0 : SwiftSyntax.AccessorDeclSyntax
                       - attributes : nil
                       - modifier : nil
                       ▿ accessorKind : SwiftSyntax.TokenSyntax
                         - text : "get"
                         ▿ leadingTrivia : Trivia
                           - pieces : 0 elements
                         ▿ trailingTrivia : Trivia
                           ▿ pieces : 1 element
                             ▿ 0 : TriviaPiece
                               - spaces : 1
                         ▿ tokenKind : TokenKind
                           - contextualKeyword : "get"
                       - parameter : nil
                       - body : nil
                   ▿ rightBrace : SwiftSyntax.TokenSyntax
                     - text : "}"
                     ▿ leadingTrivia : Trivia
                       - pieces : 0 elements
                     ▿ trailingTrivia : Trivia
                       - pieces : 0 elements
                     - tokenKind : SwiftSyntax.TokenKind.rightBrace
               - trailingComma : nil
         - semicolon : nil
       ▿ 2 : SwiftSyntax.MemberDeclListItemSyntax
         ▿ decl : SwiftSyntax.FunctionDeclSyntax
           - attributes : nil
           - modifiers : nil
           ▿ funcKeyword : SwiftSyntax.TokenSyntax
             - text : "func"
             ▿ leadingTrivia : Trivia
               ▿ pieces : 2 elements
                 ▿ 0 : TriviaPiece
                   - newlines : 1
                 ▿ 1 : TriviaPiece
                   - spaces : 4
             ▿ trailingTrivia : Trivia
               ▿ pieces : 1 element
                 ▿ 0 : TriviaPiece
                   - spaces : 1
             - tokenKind : SwiftSyntax.TokenKind.funcKeyword
           ▿ identifier : SwiftSyntax.TokenSyntax
             - text : "reloadContents"
             ▿ leadingTrivia : Trivia
               - pieces : 0 elements
             ▿ trailingTrivia : Trivia
               - pieces : 0 elements
             ▿ tokenKind : TokenKind
               - identifier : "reloadContents"
           - genericParameterClause : nil
           ▿ signature : SwiftSyntax.FunctionSignatureSyntax
             ▿ input : SwiftSyntax.ParameterClauseSyntax
               ▿ leftParen : SwiftSyntax.TokenSyntax
                 - text : "("
                 ▿ leadingTrivia : Trivia
                   - pieces : 0 elements
                 ▿ trailingTrivia : Trivia
                   - pieces : 0 elements
                 - tokenKind : SwiftSyntax.TokenKind.leftParen
               - parameterList : SwiftSyntax.FunctionParameterListSyntax
               ▿ rightParen : SwiftSyntax.TokenSyntax
                 - text : ")"
                 ▿ leadingTrivia : Trivia
                   - pieces : 0 elements
                 ▿ trailingTrivia : Trivia
                   - pieces : 0 elements
                 - tokenKind : SwiftSyntax.TokenKind.rightParen
             - throwsOrRethrowsKeyword : nil
             - output : nil
           - genericWhereClause : nil
           - body : nil
         - semicolon : nil
       ▿ 3 : SwiftSyntax.MemberDeclListItemSyntax
         ▿ decl : SwiftSyntax.FunctionDeclSyntax
           - attributes : nil
           - modifiers : nil
           ▿ funcKeyword : SwiftSyntax.TokenSyntax
             - text : "func"
             ▿ leadingTrivia : Trivia
               ▿ pieces : 2 elements
                 ▿ 0 : TriviaPiece
                   - newlines : 1
                 ▿ 1 : TriviaPiece
                   - spaces : 4
             ▿ trailingTrivia : Trivia
               ▿ pieces : 1 element
                 ▿ 0 : TriviaPiece
                   - spaces : 1
             - tokenKind : SwiftSyntax.TokenKind.funcKeyword
           ▿ identifier : SwiftSyntax.TokenSyntax
             - text : "read"
             ▿ leadingTrivia : Trivia
               - pieces : 0 elements
             ▿ trailingTrivia : Trivia
               - pieces : 0 elements
             ▿ tokenKind : TokenKind
               - identifier : "read"
           - genericParameterClause : nil
           ▿ signature : SwiftSyntax.FunctionSignatureSyntax
             ▿ input : SwiftSyntax.ParameterClauseSyntax
               ▿ leftParen : SwiftSyntax.TokenSyntax
                 - text : "("
                 ▿ leadingTrivia : Trivia
                   - pieces : 0 elements
                 ▿ trailingTrivia : Trivia
                   - pieces : 0 elements
                 - tokenKind : SwiftSyntax.TokenKind.leftParen
               ▿ parameterList : SwiftSyntax.FunctionParameterListSyntax
                 ▿ 0 : SwiftSyntax.FunctionParameterSyntax
                   - attributes : nil
                   ▿ firstName : Optional<SyntaxProtocol>
                     ▿ some : SwiftSyntax.TokenSyntax
                       - text : "identity"
                       ▿ leadingTrivia : Trivia
                         - pieces : 0 elements
                       ▿ trailingTrivia : Trivia
                         - pieces : 0 elements
                       ▿ tokenKind : TokenKind
                         - identifier : "identity"
                   - secondName : nil
                   ▿ colon : Optional<SyntaxProtocol>
                     ▿ some : SwiftSyntax.TokenSyntax
                       - text : ":"
                       ▿ leadingTrivia : Trivia
                         - pieces : 0 elements
                       ▿ trailingTrivia : Trivia
                         ▿ pieces : 1 element
                           ▿ 0 : TriviaPiece
                             - spaces : 1
                       - tokenKind : SwiftSyntax.TokenKind.colon
                   ▿ type : Optional<SyntaxProtocol>
                     ▿ some : SwiftSyntax.SimpleTypeIdentifierSyntax
                       ▿ name : SwiftSyntax.TokenSyntax
                         - text : "String"
                         ▿ leadingTrivia : Trivia
                           - pieces : 0 elements
                         ▿ trailingTrivia : Trivia
                           - pieces : 0 elements
                         ▿ tokenKind : TokenKind
                           - identifier : "String"
                       - genericArgumentClause : nil
                   - ellipsis : nil
                   - defaultArgument : nil
                   - trailingComma : nil
               ▿ rightParen : SwiftSyntax.TokenSyntax
                 - text : ")"
                 ▿ leadingTrivia : Trivia
                   - pieces : 0 elements
                 ▿ trailingTrivia : Trivia
                   - pieces : 0 elements
                 - tokenKind : SwiftSyntax.TokenKind.rightParen
             - throwsOrRethrowsKeyword : nil
             - output : nil
           - genericWhereClause : nil
           - body : nil
         - semicolon : nil
       ▿ 4 : SwiftSyntax.MemberDeclListItemSyntax
         ▿ decl : SwiftSyntax.FunctionDeclSyntax
           - attributes : nil
           - modifiers : nil
           ▿ funcKeyword : SwiftSyntax.TokenSyntax
             - text : "func"
             ▿ leadingTrivia : Trivia
               ▿ pieces : 2 elements
                 ▿ 0 : TriviaPiece
                   - newlines : 1
                 ▿ 1 : TriviaPiece
                   - spaces : 4
             ▿ trailingTrivia : Trivia
               ▿ pieces : 1 element
                 ▿ 0 : TriviaPiece
                   - spaces : 1
             - tokenKind : SwiftSyntax.TokenKind.funcKeyword
           ▿ identifier : SwiftSyntax.TokenSyntax
             - text : "trackViewDidAppear"
             ▿ leadingTrivia : Trivia
               - pieces : 0 elements
             ▿ trailingTrivia : Trivia
               - pieces : 0 elements
             ▿ tokenKind : TokenKind
               - identifier : "trackViewDidAppear"
           - genericParameterClause : nil
           ▿ signature : SwiftSyntax.FunctionSignatureSyntax
             ▿ input : SwiftSyntax.ParameterClauseSyntax
               ▿ leftParen : SwiftSyntax.TokenSyntax
                 - text : "("
                 ▿ leadingTrivia : Trivia
                   - pieces : 0 elements
                 ▿ trailingTrivia : Trivia
                   - pieces : 0 elements
                 - tokenKind : SwiftSyntax.TokenKind.leftParen
               - parameterList : SwiftSyntax.FunctionParameterListSyntax
               ▿ rightParen : SwiftSyntax.TokenSyntax
                 - text : ")"
                 ▿ leadingTrivia : Trivia
                   - pieces : 0 elements
                 ▿ trailingTrivia : Trivia
                   - pieces : 0 elements
                 - tokenKind : SwiftSyntax.TokenKind.rightParen
             - throwsOrRethrowsKeyword : nil
             - output : nil
           - genericWhereClause : nil
           - body : nil
         - semicolon : nil
     ▿ rightBrace : SwiftSyntax.TokenSyntax
       - text : "}"
       ▿ leadingTrivia : Trivia
         ▿ pieces : 1 element
           ▿ 0 : TriviaPiece
             - newlines : 1
       ▿ trailingTrivia : Trivia
         - pieces : 0 elements
       - tokenKind : SwiftSyntax.TokenKind.rightBrace
 */
