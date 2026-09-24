import Foundation
import HealthKit

enum HealthServiceError: LocalizedError {
    case healthDataUnavailable
    case dataTypeUnavailable(String)
    case authorizationFailed
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "这台设备不支持 HealthKit"
        case .dataTypeUnavailable(let name):
            return "无法获取 HealthKit 数据类型：\(name)"
        case .authorizationFailed:
            return "HealthKit 授权失败"
        case .queryFailed(let message):
            return "读取 HealthKit 失败：\(message)"
        }
    }
}

// HealthService 只负责“怎么从 HealthKit 取数据”，不负责 Agent 协议。
struct HealthWorkoutSummary {
    let type: String
    let start: Date
    let end: Date
    let durationMinutes: Double
    let energyKcal: Double?
}
struct HealthSleepSummary {
    let hours: Double
    let start: Date?
    let end: Date?
}

@MainActor
final class HealthService {
    static let shared = HealthService()

    // HKHealthStore 是 iOS 访问 HealthKit 数据库的统一入口。
    private let healthStore = HKHealthStore()
    private var didRequestAuthorization = false

    private init() {}

    /// 第一次使用健康工具时，一次申请当前 Vanta 支持的全部读取权限。
    /// 后续新增心率等能力，只需要把新的 HKObjectType 加到 readTypes。
    func requestAuthorizationIfNeeded() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthServiceError.healthDataUnavailable
        }

        guard !didRequestAuthorization else {
            return
        }

        guard
            let stepType = HKObjectType.quantityType(forIdentifier: .stepCount),
            let energyType = HKObjectType.quantityType(
                forIdentifier: .activeEnergyBurned
            ),
            let sleepType = HKObjectType.categoryType(
                forIdentifier: .sleepAnalysis
            )
        else {
            throw HealthServiceError.dataTypeUnavailable("基础健康数据")
        }
        let workoutType = HKObjectType.workoutType()

        // toShare 为空：Vanta 当前只读，不向 Apple 健康写数据。
        let readTypes: Set<HKObjectType> = [
            stepType,
            energyType,
            sleepType,
            workoutType,
        ]

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(
                toShare: [],
                read: readTypes
            ) { success, error in
                if let error {
                    continuation.resume(
                        throwing: HealthServiceError.queryFailed(
                            error.localizedDescription
                        )
                    )
                    return
                }

                guard success else {
                    continuation.resume(
                        throwing: HealthServiceError.authorizationFailed
                    )
                    return
                }

                continuation.resume()
            }
        }

        didRequestAuthorization = true
    }

    /// 查询“今天 00:00 到现在”的累计步数。
    func todaySteps() async throws -> Int {
        try await requestAuthorizationIfNeeded()

        guard let stepType = HKObjectType.quantityType(
            forIdentifier: .stepCount
        ) else {
            throw HealthServiceError.dataTypeUnavailable("步数")
        }

        let value = try await cumulativeQuantity(
            type: stepType,
            unit: .count(),
            start: Calendar.current.startOfDay(for: Date()),
            end: Date()
        )

        return Int(value.rounded())
    }

    /// 活动能量对应 Apple 健康里的 Active Energy，不是基础代谢。
    /// 返回单位统一转换成 kcal，方便 Agent 直接理解。
    func todayActiveEnergyKcal() async throws -> Double {
        try await requestAuthorizationIfNeeded()

        guard let energyType = HKObjectType.quantityType(
            forIdentifier: .activeEnergyBurned
        ) else {
            throw HealthServiceError.dataTypeUnavailable("活动能量")
        }

        return try await cumulativeQuantity(
            type: energyType,
            unit: .kilocalorie(),
            start: Calendar.current.startOfDay(for: Date()),
            end: Date()
        )
    }
    /// 获取 HealthKit 里最近结束的一次 Workout。
    func latestWorkout() async throws -> HealthWorkoutSummary? {
        try await requestAuthorizationIfNeeded()

        let workoutType = HKObjectType.workoutType()
        let sort = NSSortDescriptor(
            key: HKSampleSortIdentifierEndDate,
            ascending: false
        )

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<HealthWorkoutSummary?, Error>) in
            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(
                        throwing: HealthServiceError.queryFailed(
                            error.localizedDescription
                        )
                    )
                    return
                }

                guard let workout = samples?.first as? HKWorkout else {
                    continuation.resume(returning: nil)
                    return
                }

                let kcal = workout.totalEnergyBurned?
                    .doubleValue(for: .kilocalorie())

                continuation.resume(
                    returning: HealthWorkoutSummary(
                        type: Self.workoutName(workout.workoutActivityType),
                        start: workout.startDate,
                        end: workout.endDate,
                        durationMinutes: workout.duration / 60,
                        energyKcal: kcal
                    )
                )
            }

            healthStore.execute(query)
        }
    }

    /// “昨晚”定义为昨天 18:00 到今天 12:00。
    /// 如果当前还没到中午，则查询到当前时刻。
    func lastNightSleep() async throws -> HealthSleepSummary {
        try await requestAuthorizationIfNeeded()

        guard let sleepType = HKObjectType.categoryType(
            forIdentifier: .sleepAnalysis
        ) else {
            throw HealthServiceError.dataTypeUnavailable("睡眠")
        }

        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let start = calendar.date(
            byAdding: .hour,
            value: -6,
            to: todayStart
        ) ?? todayStart
        let noon = calendar.date(
            byAdding: .hour,
            value: 12,
            to: todayStart
        ) ?? now
        let end = min(now, noon)

        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: []
        )
        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[HKCategorySample], Error>) in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [
                    NSSortDescriptor(
                        key: HKSampleSortIdentifierStartDate,
                        ascending: true
                    )
                ]
            ) { _, samples, error in
                if let error {
                    continuation.resume(
                        throwing: HealthServiceError.queryFailed(
                            error.localizedDescription
                        )
                    )
                    return
                }

                continuation.resume(
                    returning: (samples as? [HKCategorySample]) ?? []
                )
            }

            healthStore.execute(query)
        }

        // 只统计真正 asleep 的阶段，不把“躺在床上”和“清醒”算作睡眠。
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]

        let intervals = samples
            .filter { asleepValues.contains($0.value) }
            .map { ($0.startDate, $0.endDate) }
        // Apple Watch / iPhone 可能产生重叠睡眠样本。
        // 先合并重叠区间再求时长，避免重复计时。
        let merged = Self.mergeIntervals(intervals)
        let seconds = merged.reduce(0.0) {
            $0 + $1.1.timeIntervalSince($1.0)
        }

        return HealthSleepSummary(
            hours: seconds / 3600,
            start: merged.first?.0,
            end: merged.last?.1
        )
    }

    /// 步数和活动能量都属于“某段时间内累加”的 Quantity，
    /// 所以抽成一个公共方法，避免复制两份 HKStatisticsQuery。
    private func cumulativeQuantity(
        type: HKQuantityType,
        unit: HKUnit,
        start: Date,
        end: Date
    ) async throws -> Double {
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: .strictStartDate
        )

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Double, Error>) in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, error in
                if let error {
                    continuation.resume(
                        throwing: HealthServiceError.queryFailed(
                            error.localizedDescription
                        )
                    )
                    return
                }
                let value = result?
                    .sumQuantity()?
                    .doubleValue(for: unit) ?? 0
                continuation.resume(returning: value)
            }

            healthStore.execute(query)
        }
    }

    /// 把常见 Workout 枚举翻译成人能看懂的中文。
    private static func workoutName(
        _ type: HKWorkoutActivityType
    ) -> String {
        switch type {
        case .traditionalStrengthTraining:
            return "传统力量训练"
        case .functionalStrengthTraining:
            return "功能性力量训练"
        case .running:
            return "跑步"
        case .walking:
            return "步行"
        case .cycling:
            return "骑行"
        case .swimming:
            return "游泳"
        case .hiking:
            return "徒步"
        case .highIntensityIntervalTraining:
            return "高强度间歇训练"
        case .coreTraining:
            return "核心训练"
        case .mixedCardio:
            return "混合有氧"
        case .crossTraining:
            return "交叉训练"
        case .elliptical:
            return "椭圆机"
        case .rowing:
            return "划船"
        case .stairClimbing:
            return "爬楼"
        case .yoga:
            return "瑜伽"
        case .pilates:
            return "普拉提"
        default:
            return "训练（类型 \(type.rawValue)）"
        }
    }

    /// 将重叠的 [start, end] 时间段合并。
    /// 例如 23:00-01:00 和 00:30-02:00 最终只计算 23:00-02:00。
    private static func mergeIntervals(
        _ intervals: [(Date, Date)]
    ) -> [(Date, Date)] {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        guard var current = sorted.first else {
            return []
        }

        var merged: [(Date, Date)] = []

        for interval in sorted.dropFirst() {
            if interval.0 <= current.1 {
                current.1 = max(current.1, interval.1)
            } else {
                merged.append(current)
                current = interval
            }
        }

        merged.append(current)
        return merged
    }
}
