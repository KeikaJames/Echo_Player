import Foundation
import XCTest
@testable import LyricPlayer

final class MeetingSummarizerTests: XCTestCase {
    func testLocalSummaryOnlyExtractsTranscriptFacts() throws {
        let startedAt = Date(timeIntervalSince1970: 100)
        let texts = [
            "今天讨论播放器的兼容版本。",
            "决定最低支持 macOS Sonoma 14.1。",
            "下一步由测试组负责验证 Intel 和 Apple 芯片。",
            "自动更新和全格式播放必须保持不变。",
        ]
        let entries = texts.enumerated().map { index, text in
            CaptionEntry(date: startedAt.addingTimeInterval(Double(index * 30)),
                         text: text, speaker: index % 2 + 1, timeRange: nil)
        }

        let summary = try MeetingSummarizer.summarizeLocally(entries: entries)

        XCTAssertTrue(summary.overview.contains("4 条发言"))
        XCTAssertTrue(summary.overview.contains("2 位说话人"))
        XCTAssertEqual(summary.decisions, [texts[1]])
        XCTAssertEqual(summary.actionItems, [texts[2]])
        XCTAssertTrue(summary.keyPoints.allSatisfy { texts.contains($0) })
        XCTAssertLessThanOrEqual(summary.chapters.count, 8)
        XCTAssertEqual(summary.chapters.first?.startTime, "00:00")
    }

    func testLocalSummaryRejectsEmptyTranscript() {
        XCTAssertThrowsError(try MeetingSummarizer.summarizeLocally(entries: [])) { error in
            XCTAssertEqual(error.localizedDescription, MeetingSummaryError.noTranscript.localizedDescription)
        }
    }

    func testLocalSummaryDoesNotPromoteNegatedStatements() throws {
        let texts = [
            "尚未决定发布时间。",
            "这个任务不需要完成。",
            "We have not decided the release date.",
            "Please do not follow up on this item.",
            "关于发布日期的决定尚未作出。",
            "待办暂未确定。",
            "The date remains undecided.",
            "没有人确认发布时间。",
            "Nobody confirmed the release date.",
            "发布日期尚未作出决定。",
            "The date wasn't confirmed.",
            "最终决定周五发布。",
            "下一步由测试组负责验证。",
        ]
        let entries = texts.enumerated().map { index, text in
            CaptionEntry(date: Date(timeIntervalSince1970: Double(index)),
                         text: text, speaker: nil, timeRange: nil)
        }

        let summary = try MeetingSummarizer.summarizeLocally(entries: entries)

        XCTAssertEqual(summary.decisions, [texts[11]])
        XCTAssertEqual(summary.actionItems, [texts[12]])
    }

    func testLocalSummaryKeepsNegativeDecisions() throws {
        let texts = [
            "最终决定不延期发布。",
            "We decided not to delay the release.",
            "We did not delay but finally decided to release Friday.",
            "最终决定不通过该提案。",
            "最终决定将通过该提案。",
            "下一步不延期发布。",
        ]
        let entries = texts.enumerated().map { index, text in
            CaptionEntry(date: Date(timeIntervalSince1970: Double(index)),
                         text: text, speaker: nil, timeRange: nil)
        }

        let summary = try MeetingSummarizer.summarizeLocally(entries: entries)

        XCTAssertEqual(summary.decisions, Array(texts.prefix(5)))
        XCTAssertEqual(summary.actionItems, [texts[5]])
    }

    func testLocalSummaryDoesNotPromotePendingItems() throws {
        let texts = [
            "下一步需要确认预算。",
            "预算尚待最终确认。",
            "The budget will be confirmed Friday.",
            "The plan needs to be approved.",
            "计划下周确认预算。",
            "预算将在下周正式确认。",
            "决定将在下周作出。",
            "确认预算不变。",
            "The budget was confirmed.",
        ]
        let entries = texts.enumerated().map { index, text in
            CaptionEntry(date: Date(timeIntervalSince1970: Double(index)),
                         text: text, speaker: nil, timeRange: nil)
        }

        let summary = try MeetingSummarizer.summarizeLocally(entries: entries)

        XCTAssertEqual(summary.decisions, Array(texts.suffix(2)))
        XCTAssertEqual(summary.actionItems, [texts[0]])
    }

    func testLocalSummaryDoesNotPromotePostfixedPendingItems() throws {
        let texts = [
            "决定尚待确认。",
            "这个决定有待确认。",
            "决定需要正式确认。",
            "决定可能通过。",
            "是否通过仍未决定。",
            "发布日期的决定目前仍然尚未作出。",
            "待办仍需安排。",
            "最终决定周五发布。",
        ]
        let entries = texts.enumerated().map { index, text in
            CaptionEntry(date: Date(timeIntervalSince1970: Double(index)),
                         text: text, speaker: nil, timeRange: nil)
        }

        let summary = try MeetingSummarizer.summarizeLocally(entries: entries)

        XCTAssertEqual(summary.decisions, [texts[7]])
        XCTAssertEqual(summary.actionItems, [texts[6]])
    }

    func testLocalSummaryDoesNotKeepCompletedActionItems() throws {
        let texts = [
            "张三负责的回归测试已经完成。",
            "这个待办已全部完成。",
            "The follow up was completed.",
            "The action item has been resolved.",
            "已完成待办：部署。",
            "回归测试已完成，由张三负责。",
            "待办已取消。",
            "The action item was cancelled.",
            "待办：部署；该待办已完成。",
            "最终决定周五发布，但该决定随后已撤销。",
            "阶段一已经完成，张三负责阶段二。",
            "下一步由测试组负责验证。",
            "Follow up with the release team.",
        ]
        let entries = texts.enumerated().map { index, text in
            CaptionEntry(date: Date(timeIntervalSince1970: Double(index)),
                         text: text, speaker: nil, timeRange: nil)
        }

        let summary = try MeetingSummarizer.summarizeLocally(entries: entries)

        XCTAssertTrue(summary.decisions.isEmpty)
        XCTAssertEqual(summary.actionItems, Array(texts.suffix(3)))
    }
}
