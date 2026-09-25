//
//  ConcurrencyUtils.swift
//  MinimuxerCommon
//
//  Created by Magesh K on 20/09/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

func toSendableDictionary(_ dict: [String: Any]) -> [String: any Sendable] {
    var result: [String: any Sendable] = [:]
    for (k, v) in dict {
        if let s = v as? String { result[k] = s }
        else if let d = v as? Data { result[k] = d }
        else if let dt = v as? Date { result[k] = dt }
        else if let n = v as? NSNumber { result[k] = n }
        else if let b = v as? Bool { result[k] = b }
        else if let subDict = v as? [String: Any] { result[k] = toSendableDictionary(subDict) }
    }
    return result
}
