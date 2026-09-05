// Pure parsing/math helpers for the resources widget, kept out of the QML
// file so the sampling logic can be read (and eventually tested) on its own.

// The aggregate "cpu  ..." line from /proc/stat, never a per-core "cpu0" line
// (those have no space before the digits, so the regex below skips them).
function parseCpuLine(text) {
  var m = /^cpu\s+([\d\s]+)$/m.exec(String(text || ""))
  if (!m) return null

  var parts = m[1].trim().split(/\s+/).map(Number)
  var user = parts[0] || 0, nice = parts[1] || 0, system = parts[2] || 0, idle = parts[3] || 0
  var iowait = parts[4] || 0, irq = parts[5] || 0, softirq = parts[6] || 0, steal = parts[7] || 0

  return {
    idleAll: idle + iowait,
    total: user + nice + system + idle + iowait + irq + softirq + steal
  }
}

// Percent busy between two /proc/stat samples. Null until a second sample
// exists, since a single reading has no delta to measure usage from.
function cpuPercent(prev, curr) {
  if (!prev || !curr) return null
  var totalDelta = curr.total - prev.total
  var idleDelta = curr.idleAll - prev.idleAll
  if (totalDelta <= 0) return null
  return Math.round(100 * (1 - idleDelta / totalDelta))
}

// MemAvailable (not MemFree) is the kernel's own estimate of what's usable
// without swapping, so it already accounts for reclaimable cache/buffers.
function parseMem(text) {
  var raw = String(text || "")
  var totalM = /^MemTotal:\s+(\d+)/m.exec(raw)
  var availM = /^MemAvailable:\s+(\d+)/m.exec(raw)
  if (!totalM || !availM) return null

  var totalKb = parseInt(totalM[1], 10)
  var availKb = parseInt(availM[1], 10)
  return {
    totalKb: totalKb,
    availKb: availKb,
    usedPct: totalKb > 0 ? Math.round(100 * (1 - availKb / totalKb)) : 0
  }
}

// Sum of rx/tx bytes across every interface except loopback, from
// /proc/net/dev. Format is "iface: rxBytes rxPackets ... (8 recv fields)
// txBytes txPackets ...", so the tx byte count is the first field after
// the 8 receive columns.
function parseNetDev(text) {
  var raw = String(text || "")
  var re = /^\s*([^:\s]+):\s*(\d+)(?:\s+\d+){7}\s+(\d+)/gm
  var rxBytes = 0, txBytes = 0
  var m
  while ((m = re.exec(raw)) !== null) {
    if (m[1] === "lo") continue
    rxBytes += parseInt(m[2], 10)
    txBytes += parseInt(m[3], 10)
  }
  return { rxBytes: rxBytes, txBytes: txBytes }
}

// Bytes/sec between two /proc/net/dev samples. Null until a second sample
// exists, or if a counter went backwards (an interface reset/reappeared).
function netRate(prev, curr, dtSeconds) {
  if (!prev || !curr || !(dtSeconds > 0)) return null
  var rxDelta = curr.rxBytes - prev.rxBytes
  var txDelta = curr.txBytes - prev.txBytes
  if (rxDelta < 0 || txDelta < 0) return null
  return { rxBps: rxDelta / dtSeconds, txBps: txDelta / dtSeconds }
}

// Compact human-readable byte count, e.g. "340KB", "1.2GB". Spelled-out unit
// (not the bare "K"/"G" a raw SI-prefix table gives) so it reads unambiguously
// at a glance in a tooltip or bar label.
function formatBytes(bytes) {
  var v = Math.max(0, Number(bytes) || 0)
  var units = ["B", "KB", "MB", "GB", "TB"]
  var i = 0
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024
    i++
  }
  var decimals = v < 10 && i > 0 ? 1 : 0
  return v.toFixed(decimals) + units[i]
}

// Same, plus the "/s" a rate needs to read unambiguously as speed rather
// than a one-off quantity.
function formatRate(bytesPerSec) {
  return formatBytes(bytesPerSec) + "/s"
}

// temp1_input-style sysfs content: a bare integer in millidegrees C, or
// empty when no thermal sensor was found for this hardware.
function parseTemp(text) {
  var raw = String(text || "").trim()
  if (raw === "") return null
  var v = parseFloat(raw)
  return isNaN(v) ? null : v / 1000
}

// Last line of `df -B1 --output=size,used,avail,pcent /`.
function parseDisk(text) {
  var lines = String(text || "").trim().split("\n")
  if (lines.length === 0) return null
  var cols = lines[lines.length - 1].trim().split(/\s+/)
  if (cols.length < 4) return null

  var totalBytes = parseInt(cols[0], 10)
  var usedBytes = parseInt(cols[1], 10)
  var availBytes = parseInt(cols[2], 10)
  var usedPct = parseInt(cols[3], 10) // parseInt stops at the trailing "%"
  if (isNaN(totalBytes) || isNaN(usedPct)) return null

  return { totalBytes: totalBytes, usedBytes: usedBytes, availBytes: availBytes, usedPct: usedPct }
}

// Splits one combined sample into named sections. The sampling command
// prints "===NAME===" markers between each metric's raw output so one
// process spawn can gather everything in a single read.
function splitSections(text) {
  var parts = String(text || "").split(/===([A-Z]+)===\r?\n?/)
  var sections = {}
  for (var i = 1; i < parts.length; i += 2) sections[parts[i]] = parts[i + 1] || ""
  return sections
}

if (typeof module !== "undefined") {
  module.exports = {
    parseCpuLine: parseCpuLine,
    cpuPercent: cpuPercent,
    parseMem: parseMem,
    parseNetDev: parseNetDev,
    netRate: netRate,
    formatBytes: formatBytes,
    formatRate: formatRate,
    parseTemp: parseTemp,
    parseDisk: parseDisk,
    splitSections: splitSections
  }
}
