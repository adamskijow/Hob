// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HobCalendar

@Test
func busyEventPolicyRespectsAvailabilityAllDayAndCurrentPlan() {
    let current = URL(string: "hob://schedule/current/block-1")
    let older = URL(string: "hob://schedule/older/block-1")

    #expect(!EventKitBusyEventPolicy.blocksTime(
        isAllDay: false,
        isCanceled: false,
        isFree: true,
        url: nil,
        blockAllDayEvents: false,
        excludingProposalID: nil
    ))
    #expect(!EventKitBusyEventPolicy.blocksTime(
        isAllDay: true,
        isCanceled: false,
        isFree: false,
        url: nil,
        blockAllDayEvents: false,
        excludingProposalID: nil
    ))
    #expect(EventKitBusyEventPolicy.blocksTime(
        isAllDay: true,
        isCanceled: false,
        isFree: false,
        url: nil,
        blockAllDayEvents: true,
        excludingProposalID: nil
    ))
    #expect(!EventKitBusyEventPolicy.blocksTime(
        isAllDay: false,
        isCanceled: true,
        isFree: false,
        url: nil,
        blockAllDayEvents: false,
        excludingProposalID: nil
    ))
    #expect(!EventKitBusyEventPolicy.blocksTime(
        isAllDay: false,
        isCanceled: false,
        isFree: false,
        url: current,
        blockAllDayEvents: false,
        excludingProposalID: "current"
    ))
    #expect(EventKitBusyEventPolicy.blocksTime(
        isAllDay: false,
        isCanceled: false,
        isFree: false,
        url: older,
        blockAllDayEvents: false,
        excludingProposalID: "current"
    ))
}
