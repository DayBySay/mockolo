import Foundation
import SourceKittenFramework

final class VariableModel: Model {
    var name: String
    var type: Type
    var offset: Int64
    var length: Int64
    let accessControlLevelDescription: String
    let attributes: [String]?
    var canBeInitParam: Bool
    let processed: Bool
    var data: Data? = nil
    var filePath: String = ""
    var isStatic = false
    var shouldOverride = false
    var overrideTypes: [String: String]?
    var cachedDefaultTypeVal: String?
    var modelDescription: String? = nil
    var modelType: ModelType {
        return .variable
    }

    var fullName: String {
        let suffix = isStatic ? String.static : ""
        return name + suffix
    }

    init(name: String,
         typeName: String,
         acl: String?,
         encloserType: DeclType,
         isStatic: Bool,
         canBeInitParam: Bool,
         offset: Int64,
         length: Int64,
         overrideTypes: [String: String]?,
         modelDescription: String?,
         processed: Bool) {

        self.name = name.trimmingCharacters(in: .whitespaces)
        self.type = Type(typeName.trimmingCharacters(in: .whitespaces))
        self.offset = offset
        self.length = length
        self.isStatic = isStatic
        self.shouldOverride = encloserType == .classType
        self.canBeInitParam = canBeInitParam
        self.processed = processed
        self.overrideTypes = overrideTypes
        self.accessControlLevelDescription = acl ?? ""
        self.attributes = nil
        self.modelDescription = modelDescription
    }
    
    init(_ ast: Structure, encloserType: DeclType, filepath: String, data: Data, overrideTypes: [String: String]?, processed: Bool) {
        name = ast.name
        type = Type(ast.typeName)
        offset = ast.range.offset
        length = ast.range.length
        canBeInitParam = ast.canBeInitParam
        isStatic = ast.isStaticVariable
        shouldOverride = ast.isOverride || encloserType == .classType
        accessControlLevelDescription = ast.accessControlLevelDescription
        attributes = ast.hasAvailableAttribute ? ast.extractAttributes(data, filterOn: SwiftDeclarationAttributeKind.available.rawValue) : nil
        self.processed = processed
        self.overrideTypes = overrideTypes
        self.data = data
        self.filePath = filepath
    }
    
    func render(with identifier: String, encloser: String) -> String? {
        
        if processed {
            var prefix = ""
            if shouldOverride, !name.isGenerated(type: type) {
                prefix = "\(String.override) "
            }
            if let modelDescription = modelDescription?.trimmingCharacters(in: .newlines), !modelDescription.isEmpty {
                return prefix + modelDescription
            }
            
            if let ret = self.data?.toString(offset: self.offset, length: self.length) {
                if !ret.contains(identifier),
                    let first = ret.components(separatedBy: CharacterSet(arrayLiteral: ":", "=")).first,
                    let found = first.components(separatedBy: " ").filter({!$0.isEmpty}).last {
                    let replaced = ret.replacingOccurrences(of: found, with: identifier)
                    return prefix + replaced
                }

                return prefix + ret
            }
            return nil
        }

        if let rxVar = applyRxVariableTemplate(name: identifier,
                                               type: type,
                                               overrideTypes: overrideTypes,
                                               encloser: encloser,
                                               isStatic: isStatic,
                                               shouldOverride: shouldOverride,
                                               accessControlLevelDescription: accessControlLevelDescription) {
            return rxVar
        }
        return applyVariableTemplate(name: identifier,
                                     type: type,
                                     encloser: encloser,
                                     isStatic: isStatic,
                                     shouldOverride: shouldOverride,
                                     accessControlLevelDescription: accessControlLevelDescription)
    }
}
