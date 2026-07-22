//
//  WordReplacement.swift
//  PindropData
//
//  Created on 2026-01-27.
//

import Foundation
import SwiftData
import PindropCore

@Model
public final class WordReplacement {

    @Attribute(.unique) public var id: UUID
    public var originals: [String]
    public var replacement: String
    public var createdAt: Date
    public var sortOrder: Int
    /// Nil means case-insensitive (historical default).
    public var matchModeRawValue: String?
    public var usageCount: Int = 0

    public init(
        id: UUID = UUID(),
        originals: [String],
        replacement: String,
        createdAt: Date = Date(),
        sortOrder: Int = 0,
        matchModeRawValue: String? = nil,
        usageCount: Int = 0
    ) {
        self.id = id
        self.originals = originals
        self.replacement = replacement
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.matchModeRawValue = matchModeRawValue
        self.usageCount = usageCount
    }

    /// Resolved match mode; nil or unknown raw values fall back to case-insensitive.
    public var matchMode: ReplacementMatchMode {
        guard let matchModeRawValue,
              let mode = ReplacementMatchMode(rawValue: matchModeRawValue) else {
            return .caseInsensitive
        }
        return mode
    }
}
