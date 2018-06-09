//
//  WatchDataManager.swift
//  Loop
//
//  Created by Nathan Racklyeft on 5/29/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import HealthKit
import UIKit
import WatchConnectivity
import CarbKit
import LoopKit


final class WatchDataManager: NSObject, WCSessionDelegate {

    unowned let deviceDataManager: DeviceDataManager

    init(deviceDataManager: DeviceDataManager) {
        self.deviceDataManager = deviceDataManager

        super.init()

        NotificationCenter.default.addObserver(self, selector: #selector(updateWatch(_:)), name: .LoopDataUpdated, object: deviceDataManager.loopManager)

        watchSession?.delegate = self
        watchSession?.activate()
    }

    private var watchSession: WCSession? = {
        if WCSession.isSupported() {
            return WCSession.default
        } else {
            return nil
        }
    }()

    private var lastActiveOverrideContext: GlucoseRangeSchedule.Override.Context?
    private var lastConfiguredOverrideContexts: [GlucoseRangeSchedule.Override.Context] = []

    @objc private func updateWatch(_ notification: Notification) {
        guard
            let rawUpdateContext = notification.userInfo?[LoopDataManager.LoopUpdateContextKey] as? LoopDataManager.LoopUpdateContext.RawValue,
            let updateContext = LoopDataManager.LoopUpdateContext(rawValue: rawUpdateContext),
            let session = watchSession
        else {
            return
        }

        switch updateContext {
        case .tempBasal:
            break
        case .preferences:
            let activeOverrideContext = deviceDataManager.loopManager.settings.glucoseTargetRangeSchedule?.activeOverrideContext
            let configuredOverrideContexts = deviceDataManager.loopManager.settings.glucoseTargetRangeSchedule?.configuredOverrideContexts ?? []
            defer {
                lastActiveOverrideContext = activeOverrideContext
                lastConfiguredOverrideContexts = configuredOverrideContexts
            }

            guard activeOverrideContext != lastActiveOverrideContext || configuredOverrideContexts != lastConfiguredOverrideContexts else {
                return
            }
        default:
            return
        }

        switch session.activationState {
        case .notActivated, .inactive:
            session.activate()
        case .activated:
            createWatchContext { (context) in
                if let context = context {
                    self.sendWatchContext(context)
                }
            }
        }
    }

    private var lastComplicationContext: WatchContext?

    private let minTrendDrift: Double = 20
    private lazy var minTrendUnit = HKUnit.milligramsPerDeciliter()

    private func sendWatchContext(_ context: WatchContext) {
        if let session = watchSession, session.isPaired && session.isWatchAppInstalled {
            let complicationShouldUpdate: Bool

            if let lastContext = lastComplicationContext,
                let lastGlucose = lastContext.glucose, let lastGlucoseDate = lastContext.glucoseDate,
                let newGlucose = context.glucose, let newGlucoseDate = context.glucoseDate
            {
                let enoughTimePassed = newGlucoseDate.timeIntervalSince(lastGlucoseDate).minutes >= 30
                let enoughTrendDrift = abs(newGlucose.doubleValue(for: minTrendUnit) - lastGlucose.doubleValue(for: minTrendUnit)) >= minTrendDrift

                complicationShouldUpdate = enoughTimePassed || enoughTrendDrift
            } else {
                complicationShouldUpdate = true
            }

            if session.isComplicationEnabled && complicationShouldUpdate {
                session.transferCurrentComplicationUserInfo(context.rawValue)
                lastComplicationContext = context
            } else {
                do {
                    try session.updateApplicationContext(context.rawValue)
                } catch let error {
                    deviceDataManager.logger.addError(error, fromSource: "WCSession")
                }
            }
        }
    }

    private func createWatchContext(_ completion: @escaping (_ context: WatchContext?) -> Void) {
        let loopManager = deviceDataManager.loopManager!

        let glucose = loopManager.glucoseStore.latestGlucose
        let reservoir = loopManager.doseStore.lastReservoirValue

        loopManager.glucoseStore.preferredUnit { (unit, error) in
            loopManager.getLoopState { (manager, state) in
                let eventualGlucose = state.predictedGlucose?.last
                let context = WatchContext(glucose: glucose, eventualGlucose: eventualGlucose, glucoseUnit: unit)
                context.reservoir = reservoir?.unitVolume

                context.loopLastRunDate = state.lastLoopCompleted
                context.recommendedBolusDose = state.recommendedBolus?.recommendation.amount
                context.maxBolus = manager.settings.maximumBolus

                let updateGroup = DispatchGroup()

                updateGroup.enter()
                manager.doseStore.insulinOnBoard(at: Date()) {(result) in
                    // This function completes asynchronously, so below
                    // is a completion that returns a value after eventual
                    // function completion.
                    switch result {
                    case .success(let iobValue):
                        context.IOB = iobValue.value
                    case .failure:
                        context.IOB = nil
                    }
                    updateGroup.leave()
                }
  
                if let cobValue = state.carbsOnBoard {
                    context.COB = cobValue.quantity.doubleValue(for: HKUnit.gram())
                } else {
                // we expect state.carbsOnBoard to be nil if value is zero:
                    context.COB = 0.0
                }
                
                let date = state.lastTempBasal?.startDate ?? Date()
                // Only set this value in the Watch context if there is a temp basal
                // running that hasn't ended yet:
                if let scheduledBasal = manager.basalRateSchedule?.between(start: date, end: date).first,  let lastTempBasal = state.lastTempBasal, lastTempBasal.endDate > Date() {
                    context.lastNetTempBasalDose =  (state.lastTempBasal?.unitsPerHour)! - scheduledBasal.value
                } else {
                    context.lastNetTempBasalDose = nil
                }
                
                // Dummy image for now as a placeholder to see if we can
                // set and send this:
                
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 270, height: 150))
                let glucoseGraphData = renderer.pngData { (imContext) in
                    UIColor.darkGray.setStroke()
                    imContext.stroke(renderer.format.bounds)
                    UIColor(red:158/255, green:215/255, blue:245/255, alpha:1).setFill()
                    imContext.fill(CGRect(x:1, y:1, width:250, height:75))
                    UIColor(red:145/255, green:211/255, blue:205/255, alpha:1).setFill()
                    imContext.fill(CGRect(x:130, y:30, width:139, height:115), blendMode: .multiply)
                }
                
                context.glucoseGraphImageData = glucoseGraphData
                
 
                if let glucoseTargetRangeSchedule = manager.settings.glucoseTargetRangeSchedule {
                    if let override = glucoseTargetRangeSchedule.override {
                        context.glucoseRangeScheduleOverride = GlucoseRangeScheduleOverrideUserInfo(
                            context: override.context.correspondingUserInfoContext,
                            startDate: override.start,
                            endDate: override.end
                        )
                    }

                    let configuredOverrideContexts = self.deviceDataManager.loopManager.settings.glucoseTargetRangeSchedule?.configuredOverrideContexts ?? []
                    let configuredUserInfoOverrideContexts = configuredOverrideContexts.map { $0.correspondingUserInfoContext }
                    context.configuredOverrideContexts = configuredUserInfoOverrideContexts
                }

                if let trend = self.deviceDataManager.sensorInfo?.trendType {
                    context.glucoseTrendRawValue = trend.rawValue
                }

                updateGroup.notify(queue: DispatchQueue.global(qos: .background)) {
                    completion(context)
                }

            }
        }
    }

    private func addCarbEntryFromWatchMessage(_ message: [String: Any], completionHandler: ((_ units: Double?) -> Void)? = nil) {
        if let carbEntry = CarbEntryUserInfo(rawValue: message) {
            let newEntry = NewCarbEntry(
                quantity: HKQuantity(unit: deviceDataManager.loopManager.carbStore.preferredUnit, doubleValue: carbEntry.value),
                startDate: carbEntry.startDate,
                foodType: nil,
                absorptionTime: carbEntry.absorptionTimeType.absorptionTimeFromDefaults(deviceDataManager.loopManager.carbStore.defaultAbsorptionTimes)
            )

            deviceDataManager.loopManager.addCarbEntryAndRecommendBolus(newEntry) { (result) in
                switch result {
                case .success(let recommendation):
                    AnalyticsManager.shared.didAddCarbsFromWatch(carbEntry.value)
                    completionHandler?(recommendation?.amount)
                case .failure(let error):
                    self.deviceDataManager.logger.addError(error, fromSource: error is CarbStore.CarbStoreError ? "CarbStore" : "Bolus")
                    completionHandler?(nil)
                }
            }
        } else {
            completionHandler?(nil)
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        switch message["name"] as? String {
        case CarbEntryUserInfo.name?:
            addCarbEntryFromWatchMessage(message) { (units) in
                replyHandler(BolusSuggestionUserInfo(recommendedBolus: units ?? 0, maxBolus: self.deviceDataManager.loopManager.settings.maximumBolus).rawValue)
            }
        case SetBolusUserInfo.name?:
            if let bolus = SetBolusUserInfo(rawValue: message as SetBolusUserInfo.RawValue) {
                self.deviceDataManager.enactBolus(units: bolus.value, at: bolus.startDate) { (error) in
                    if error == nil {
                        AnalyticsManager.shared.didSetBolusFromWatch(bolus.value)
                    }
                }
            }

            replyHandler([:])
        case GlucoseRangeScheduleOverrideUserInfo.name?:
            if let overrideUserInfo = GlucoseRangeScheduleOverrideUserInfo(rawValue: message) {
                let overrideContext = overrideUserInfo.context.correspondingOverrideContext

                // update the recorded last active override context prior to enabling the actual override
                // to prevent the Watch context being unnecessarily sent in response to the override being enabled
                let previousActiveOverrideContext = lastActiveOverrideContext
                lastActiveOverrideContext = overrideContext
                let overrideSuccess = deviceDataManager.loopManager.settings.glucoseTargetRangeSchedule?.setOverride(overrideContext, from: overrideUserInfo.startDate, until: overrideUserInfo.effectiveEndDate)

                if overrideSuccess == false {
                    lastActiveOverrideContext = previousActiveOverrideContext
                }

                replyHandler([:])
            } else {
                lastActiveOverrideContext = nil
                deviceDataManager.loopManager.settings.glucoseTargetRangeSchedule?.clearOverride()
                replyHandler([:])
            }
        default:
            replyHandler([:])
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        addCarbEntryFromWatchMessage(userInfo)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        switch activationState {
        case .activated:
            if let error = error {
                deviceDataManager.logger.addError(error, fromSource: "WCSession")
            }
        case .inactive, .notActivated:
            break
        }
    }

    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        if let error = error {
            deviceDataManager.logger.addError(error, fromSource: "WCSession")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        // Nothing to do here
    }

    func sessionDidDeactivate(_ session: WCSession) {
        watchSession = WCSession.default
        watchSession?.delegate = self
        watchSession?.activate()
    }
}

fileprivate extension GlucoseRangeSchedule.Override.Context {
    var correspondingUserInfoContext: GlucoseRangeScheduleOverrideUserInfo.Context {
        switch self {
        case .preMeal:
            return .preMeal
        case .workout:
            return .workout
        }
    }
}

fileprivate extension GlucoseRangeScheduleOverrideUserInfo.Context {
    var correspondingOverrideContext: GlucoseRangeSchedule.Override.Context {
        switch self {
        case .preMeal:
            return .preMeal
        case .workout:
            return .workout
        }
    }
}
