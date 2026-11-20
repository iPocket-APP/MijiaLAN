import MijiaCore
import MijiaLAN
import SwiftUI

struct PurifierReadings {
    struct Metric {
        let value: Double?
        let unit: String

        var number: String? { value.map(DevicePresentation.number) }
        var formatted: String? { number.map { $0 + unit } }
    }

    let particulate: Metric?
    let temperature: Metric?
    let humidity: Metric?
    let filterLife: Metric?
    let filterTime: Metric?

    var hasEnvironment: Bool { particulate != nil || temperature != nil || humidity != nil }
    var hasFilter: Bool { filterLife != nil || filterTime != nil }
    var filterText: String? {
        let parts = [filterLife?.formatted, filterTime?.formatted].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    init?(_ snapshot: DeviceSnapshot) {
        guard snapshot.isOnline, snapshot.schema.category == "air-purifier" else { return nil }
        func metric(_ service: String, _ property: String) -> Metric? {
            guard let capability = snapshot.capability(service, property), capability.readable, capability.isNumeric else { return nil }
            return Metric(value: snapshot.value(capability.id)?.doubleValue, unit: capability.displayUnit)
        }
        particulate = metric("environment", "pm2.5-density")
        temperature = metric("environment", "temperature")
        humidity = metric("environment", "relative-humidity")
        filterLife = metric("filter", "filter-life-level")
        filterTime = metric("filter", "filter-left-time")
        guard hasEnvironment || hasFilter else { return nil }
    }
}

struct PurifierReadingsCard: View {
    let readings: PurifierReadings
    @Environment(\.colorScheme) private var scheme
    private var noReading: String { L10n.tr("尚无读数", "No reading") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if readings.hasEnvironment {
                HStack(spacing: 12) {
                    if let pm = readings.particulate {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PM2.5").font(.caption).foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(pm.number ?? "—").font(.system(size: 29, weight: .medium)).monospacedDigit()
                                if pm.value != nil {
                                    Text(pm.unit.trimmingCharacters(in: .whitespaces)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("PM2.5").accessibilityValue(pm.formatted ?? noReading)
                    }
                    if readings.temperature != nil || readings.humidity != nil {
                        if readings.particulate != nil { Divider() }
                        VStack(spacing: 6) {
                            if let temperature = readings.temperature {
                                environmentRow(L10n.tr("温度", "Temperature"), symbol: "thermometer", metric: temperature)
                            }
                            if let humidity = readings.humidity {
                                environmentRow(L10n.tr("湿度", "Humidity"), symbol: "drop", metric: humidity)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if readings.hasFilter {
                if readings.hasEnvironment { Divider() }
                let title = L10n.tr("滤芯剩余", "Filter remaining")
                HStack(spacing: 8) {
                    Text(title).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let percent = readings.filterLife?.value, readings.filterLife?.unit == "%" {
                        ProgressView(value: percent, total: 100)
                            .progressViewStyle(.linear).controlSize(.mini).frame(width: 40)
                    }
                    Text(readings.filterText ?? "—").monospacedDigit()
                }
                .font(.callout)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title).accessibilityValue(readings.filterText ?? noReading)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(ControlCenterPalette(scheme: scheme).subtle, in: .rect(cornerRadius: 10))
    }

    private func environmentRow(_ title: String, symbol: String, metric: PurifierReadings.Metric) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).frame(width: 12).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(metric.formatted ?? "—").monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title).accessibilityValue(metric.formatted ?? noReading)
    }
}
