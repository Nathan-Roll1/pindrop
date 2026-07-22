//
//  VocabularyWord.swift
//  PindropData
//
//  Created on 2026-01-27.
//

import Foundation
import SwiftData

@Model
public final class VocabularyWord {

    @Attribute(.unique) public var id: UUID
    public var word: String
    public var createdAt: Date
    public var usageCount: Int = 0

    public init(
        id: UUID = UUID(),
        word: String,
        createdAt: Date = Date(),
        usageCount: Int = 0
    ) {
        self.id = id
        self.word = word
        self.createdAt = createdAt
        self.usageCount = usageCount
    }
}
