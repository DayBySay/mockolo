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


extension VariableModel {

    func applyVariableTemplate(name: String,
                               type: Type,
                               encloser: String,
                               isStatic: Bool,
                               shouldOverride: Bool,
                               accessControlLevelDescription: String) -> String {
        
        let underlyingSetCallCount = "\(name)\(String.setCallCountSuffix)"
        let underlyingVarDefaultVal = type.defaultVal()
        var underlyingType = type.typeName
        if underlyingVarDefaultVal == nil {
            underlyingType = type.underlyingType
        }
        
        let overrideStr = shouldOverride ? "\(String.override) " : ""
        var acl = accessControlLevelDescription
        if !acl.isEmpty {
            acl = acl + " "
        }
        
        var assignVal = ""
        if let val = underlyingVarDefaultVal {
            assignVal = "= \(val)"
        }
        
        let setCallCountStmt = "\(underlyingSetCallCount) += 1"
        
        var template = ""
        if isStatic || underlyingVarDefaultVal == nil {
//            if staticKind.isEmpty {
//                setCallCountStmt = "if \(String.doneInit) { \(underlyingSetCallCount) += 1 }"
//            }
            let staticSpace = isStatic ? "\(String.static) " : ""
            
//            template = """
//            \(1.tab)\(acl)\(staticStr)var \(underlyingSetCallCount) = 0
//            \(1.tab)\(staticStr)var \(underlyingName): \(underlyingType) \(assignVal)
//            \(1.tab)\(acl)\(staticStr)\(overrideStr)var \(name): \(type.typeName) {
//            \(2.tab)get { return \(underlyingName) }
//            \(2.tab)set {
//            \(3.tab)\(underlyingName) = newValue
//            \(3.tab)\(setCallCountStmt)
//            \(2.tab)}
//            \(1.tab)}
//            """
            template = """
            \(1.tab)\(acl)\(staticSpace)var \(underlyingSetCallCount) = 0
            \(1.tab)\(staticSpace)private var \(underlyingName): \(underlyingType) \(assignVal) { didSet { \(setCallCountStmt) } }
            \(1.tab)\(acl)\(staticSpace)\(overrideStr)var \(name): \(type.typeName) {
            \(2.tab)get { return \(underlyingName) }
            \(2.tab)set { \(underlyingName) = newValue }
            \(1.tab)}
            """
        } else {
            template = """
            \(1.tab)\(acl)var \(underlyingSetCallCount) = 0
            \(1.tab)\(acl)\(overrideStr)var \(name): \(type.typeName) \(assignVal) { didSet { \(setCallCountStmt) } }
            """
        }
        
        return template
    }
    
    func applyRxVariableTemplate(name: String,
                                 type: Type,
                                 overrideTypes: [String: String]?,
                                 encloser: String,
                                 isStatic: Bool,
                                 shouldOverride: Bool,
                                 accessControlLevelDescription: String) -> String? {
        
        
        let staticSpace = isStatic ? "\(String.static) " : ""
        
        if let overrideTypes = overrideTypes, !overrideTypes.isEmpty {
            let (subjectType, typeParam, subjectVal) = type.parseRxVar(overrides: overrideTypes, overrideKey: name, isInitParam: true)
            if let underlyingSubjectType = subjectType {
                
                let underlyingSubjectName = "\(name)\(String.subjectSuffix)"
                let underlyingSetCallCount = "\(underlyingSubjectName)\(String.setCallCountSuffix)"
                
                var defaultValAssignStr = ""
                if let underlyingSubjectTypeDefaultVal = subjectVal {
                    defaultValAssignStr = " = \(underlyingSubjectTypeDefaultVal)"
                } else {
                    defaultValAssignStr = ": \(underlyingSubjectType)!"
                }
                
                let acl = accessControlLevelDescription.isEmpty ? "" : accessControlLevelDescription + " "
                let overrideStr = shouldOverride ? "\(String.override) " : ""
                
                
                let incrementCallCount = "\(underlyingSetCallCount) += 1"
                let setCallCountStmt = incrementCallCount // staticKind.isEmpty ? "if \(String.doneInit) { \(incrementCallCount) }" : incrementCallCount
                let fallbackName =  "\(String.underlyingVarPrefix)\(name.capitlizeFirstLetter)"
                var fallbackType = type.typeName
                if type.isIUO || type.isOptional {
                    fallbackType.removeLast()
                }
                
                let template = """
                \(1.tab)\(acl)\(staticSpace)var \(underlyingSetCallCount) = 0
                \(1.tab)\(staticSpace)var \(fallbackName): \(fallbackType)? { didSet { \(setCallCountStmt) } }
                \(1.tab)\(acl)\(staticSpace)var \(underlyingSubjectName)\(defaultValAssignStr) { didSet { \(setCallCountStmt) } }
                \(1.tab)\(acl)\(staticSpace)\(overrideStr)var \(name): \(type.typeName) {
                \(2.tab)get { return \(fallbackName) ?? \(underlyingSubjectName) }
                \(2.tab)set { if let val = newValue as? \(underlyingSubjectType) { \(underlyingSubjectName) = val } else { \(fallbackName) = newValue } }
                \(1.tab)}
                """
                
                return template
            }
        }
        
        let typeName = type.typeName
        if let range = typeName.range(of: String.observableLeftAngleBracket), let lastIdx = typeName.lastIndex(of: ">") {
            let typeParamStr = typeName[range.upperBound..<lastIdx]
            
            let underlyingSubjectName = "\(name)\(String.subjectSuffix)"
            let underlyingSetCallCount = "\(underlyingSubjectName)\(String.setCallCountSuffix)"
            let publishSubjectName = underlyingSubjectName
            let publishSubjectType = "\(String.publishSubject)<\(typeParamStr)>"
            let behaviorSubjectName = "\(name)\(String.behaviorSubject)"
            let behaviorSubjectType = "\(String.behaviorSubject)<\(typeParamStr)>"
            let replaySubjectName = "\(name)\(String.replaySubject)"
            let replaySubjectType = "\(String.replaySubject)<\(typeParamStr)>"
            let placeholderVal = "\(String.observableLeftAngleBracket)\(typeParamStr)>.empty()"

            let acl = accessControlLevelDescription.isEmpty ? "" : accessControlLevelDescription + " "
            let overrideStr = shouldOverride ? "\(String.override) " : ""

            var mockObservableInitArgs = ""
            if type.isIUO || type.isOptional {
                mockObservableInitArgs = "(wrappedValue: \(placeholderVal), unwrapped: \(placeholderVal))"
            } else {
                mockObservableInitArgs = "(unwrapped: \(placeholderVal))"
            }
            
            let thisStr = isStatic ? encloser : "self"
            let template = """
            \(1.tab)\(acl)\(staticSpace)var \(underlyingSetCallCount): Int { return \(thisStr)._\(name).callCount }
            \(1.tab)\(acl)\(staticSpace)var \(publishSubjectName): \(publishSubjectType) { return \(thisStr)._\(name).publishSubject }
            \(1.tab)\(acl)\(staticSpace)var \(replaySubjectName): \(replaySubjectType) { return \(thisStr)._\(name).replaySubject }
            \(1.tab)\(acl)\(staticSpace)var \(behaviorSubjectName): \(behaviorSubjectType) { return \(thisStr)._\(name).behaviorSubject }
            \(1.tab)\(String.mockObservable)\(mockObservableInitArgs) \(acl)\(staticSpace)\(overrideStr)var \(name): \(typeName)
            """
            return template
        }
        return nil
    }
}

