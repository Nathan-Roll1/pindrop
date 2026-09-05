//
// PromptPreset.swift
// PindropData
//
// Created on 2026-02-02.
//

import Foundation
import SwiftData

@Model
public final class PromptPreset {

    @Attribute(.unique) public var id: UUID
    public var name: String
    public var prompt: String
    public var isBuiltIn: Bool
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var builtInIdentifier: String?

    public init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        isBuiltIn: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        builtInIdentifier: String? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.builtInIdentifier = builtInIdentifier
    }
}
