import Foundation

/// 互动视频: one module (edge) of a story graph, `/x/stein/edgeinfo_v2`.
public struct StoryEdge: Sendable, Equatable {
    public struct Choice: Sendable, Equatable {
        /// The module this choice leads to.
        public var edgeID: Int
        public var cid: Int
        public var text: String
        /// When the choice is offered, e.g. `$abc>=1 && $abc<=80`; empty = always.
        public var condition: String
        /// Run when chosen, e.g. `$abc=$abc+1;$def=0`.
        public var action: String
        public var isDefault: Bool
        public var isHidden: Bool
    }

    public struct Question: Sendable, Equatable {
        /// 0: no buttons, the first choice whose condition holds is taken automatically.
        public var type: Int
        /// Time to answer (seconds); nil = no limit.
        public var timeLimit: Double?
        public var choices: [Choice]
    }

    public struct Variable: Sendable, Equatable {
        public var id: String
        public var name: String
        public var value: Double
        /// Bilibili rolls these on every module.
        public var isRandom: Bool
        public var isShown: Bool
    }

    public var edgeID: Int
    public var title: String
    public var questions: [Question]
    public var variables: [Variable]
    /// An ending: nothing follows.
    public var isLeaf: Bool

    public init(edgeID: Int, title: String, questions: [Question], variables: [Variable], isLeaf: Bool) {
        self.edgeID = edgeID
        self.title = title
        self.questions = questions
        self.variables = variables
        self.isLeaf = isLeaf
    }

    public init(json data: JSON) {
        edgeID = data["edge_id"].intValue
        title = data["title"].stringValue
        questions = data["edges"]["questions"].array.map { q in
            let limit = q["duration"].doubleValue
            return Question(type: q["type"].intValue, timeLimit: limit > 0 ? limit / 1000 : nil,
                            choices: q["choices"].array.compactMap { c in
                                guard c["id"].intValue > 0, c["cid"].intValue > 0 else { return nil }
                                return Choice(edgeID: c["id"].intValue, cid: c["cid"].intValue, text: c["option"].stringValue,
                                              condition: c["condition"].stringValue, action: c["native_action"].stringValue,
                                              isDefault: c["is_default"].bool, isHidden: c["is_hidden"].bool)
                            })
        }.filter { !$0.choices.isEmpty }
        variables = data["hidden_vars"].array.compactMap { v in
            // Conditions name variables as `$id`; some responses already include the `$`.
            var id = v["id_v2"].string.flatMap { $0.isEmpty ? nil : $0 } ?? v["id"].stringValue
            if id.hasPrefix("$") { id.removeFirst() }
            guard !id.isEmpty else { return nil }
            return Variable(id: id, name: v["name"].stringValue, value: v["value"].doubleValue,
                            isRandom: v["type"].intValue == 2, isShown: v["is_show"].bool)
        }
        isLeaf = data["is_leaf"].bool || questions.isEmpty
    }
}

/// The player's side of a story: variable values carried from module to module, and the path taken.
public struct StoryState: Sendable, Equatable {
    public private(set) var values: [String: Double] = [:]

    public init() {}

    /// Takes the variables of a module just entered: new ones start at Bilibili's value, random ones are re-rolled
    /// by Bilibili and taken as given, the rest keep what earlier choices made them.
    public mutating func enter(_ edge: StoryEdge) {
        for v in edge.variables where v.isRandom || values[v.id] == nil {
            values[v.id] = v.value
        }
    }

    /// Choices of a question the viewer may pick (hidden ones are only taken automatically).
    public func visibleChoices(_ question: StoryEdge.Question) -> [StoryEdge.Choice] {
        question.choices.filter { !$0.isHidden && allows($0) }
    }

    /// The choice taken without asking: for type-0 questions, or when the timer runs out.
    public func automaticChoice(_ question: StoryEdge.Question) -> StoryEdge.Choice? {
        let open = question.choices.filter(allows)
        return open.first(where: \.isDefault) ?? open.first
    }

    public func allows(_ choice: StoryEdge.Choice) -> Bool {
        let condition = choice.condition.trimmingCharacters(in: .whitespaces)
        guard !condition.isEmpty else { return true }
        // An expression we can't read shouldn't hide the way forward.
        return (try? StoryExpression.evaluate(condition, values)).map { $0 != 0 } ?? true
    }

    public mutating func choose(_ choice: StoryEdge.Choice) {
        for statement in choice.action.split(separator: ";") {
            let parts = statement.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            // Only `$name = expression` (not a comparison such as `$a >= 1` or `$a == 1`).
            guard name.hasPrefix("$"), name.count > 1, name.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                  parts[1].first != "=",
                  let value = try? StoryExpression.evaluate(String(parts[1]), values) else { continue }
            values[String(name.dropFirst())] = value
        }
    }
}

/// Arithmetic / comparison / logic over `$variables`, as used in story conditions and actions.
enum StoryExpression {
    struct Invalid: Error {}

    private enum Token: Equatable {
        case number(Double), variable(String), op(String), open, close
    }

    static func evaluate(_ text: String, _ values: [String: Double]) throws -> Double {
        var parser = Parser(tokens: try tokenize(text), values: values)
        let value = try parser.parse(0)
        guard parser.index == parser.tokens.count else { throw Invalid() }
        return value
    }

    private static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
            } else if c.isNumber || c == "." {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                guard let n = Double(String(chars[i ..< j])) else { throw Invalid() }
                tokens.append(.number(n))
                i = j
            } else if c == "$" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                guard j > i + 1 else { throw Invalid() }
                tokens.append(.variable(String(chars[i + 1 ..< j])))
                i = j
            } else if c == "(" {
                tokens.append(.open); i += 1
            } else if c == ")" {
                tokens.append(.close); i += 1
            } else {
                let two = i + 1 < chars.count ? String(chars[i ... i + 1]) : ""
                if ["&&", "||", ">=", "<=", "==", "!="].contains(two) {
                    tokens.append(.op(two)); i += 2
                } else if "+-*/<>!".contains(c) {
                    tokens.append(.op(String(c))); i += 1
                } else {
                    throw Invalid()
                }
            }
        }
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        let values: [String: Double]
        var index = 0

        private static let precedence: [String: Int] = ["||": 1, "&&": 2, "==": 3, "!=": 3, "<": 4, "<=": 4, ">": 4, ">=": 4,
                                                        "+": 5, "-": 5, "*": 6, "/": 6]

        mutating func parse(_ minimum: Int) throws -> Double {
            var left = try unary()
            while index < tokens.count, case let .op(op) = tokens[index], let p = Self.precedence[op], p > minimum {
                index += 1
                let right = try parse(p)
                left = Self.apply(op, left, right)
            }
            return left
        }

        private mutating func unary() throws -> Double {
            guard index < tokens.count else { throw Invalid() }
            let token = tokens[index]
            index += 1
            switch token {
            case let .number(n): return n
            case let .variable(name): return values[name] ?? 0
            case .op("-"): return -(try unary())
            case .op("!"): return try unary() == 0 ? 1 : 0
            case .open:
                let value = try parse(0)
                guard index < tokens.count, tokens[index] == .close else { throw Invalid() }
                index += 1
                return value
            default: throw Invalid()
            }
        }

        private static func apply(_ op: String, _ a: Double, _ b: Double) -> Double {
            func flag(_ x: Bool) -> Double { x ? 1 : 0 }
            switch op {
            case "+": return a + b
            case "-": return a - b
            case "*": return a * b
            case "/": return b == 0 ? 0 : a / b
            case "<": return flag(a < b)
            case "<=": return flag(a <= b + 1e-9)
            case ">": return flag(a > b)
            case ">=": return flag(a >= b - 1e-9)
            case "==": return flag(abs(a - b) < 1e-9)
            case "!=": return flag(abs(a - b) >= 1e-9)
            case "&&": return flag(a != 0 && b != 0)
            default: return flag(a != 0 || b != 0)
            }
        }
    }
}

public extension API {
    /// 互动视频: the story graph of a video, from `player/v2`; nil for ordinary videos.
    static func storyGraphVersion(fromPlayerInfo info: JSON) -> Int? {
        let version = info["interaction"]["graph_version"].intValue
        return version > 0 ? version : nil
    }

    /// A module of the story (`edgeID` 0 = the start).
    static func storyEdge(aid: Int, bvid: String, graphVersion: Int, edgeID: Int) async throws -> StoryEdge {
        var params = ["graph_version": String(graphVersion)]
        if bvid.isEmpty { params["aid"] = String(aid) } else { params["bvid"] = bvid }
        if edgeID > 0 { params["edge_id"] = String(edgeID) }
        let json = try await client.get("https://api.bilibili.com/x/stein/edgeinfo_v2", params)
        return StoryEdge(json: json["data"])
    }
}
