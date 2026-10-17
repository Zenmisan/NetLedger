.pragma library

/**
 * Model.js - Stateless logic, SQL query generator, and data transform
 * for NetLedger (dev.zenmi.netledger) Quickshell plugin.
 */

// Format byte values into human-readable strings (e.g. 1.42 GB, 310.0 MB)
function formatBytes(bytes, decimals) {
    if (bytes === undefined || bytes === null || isNaN(bytes)) bytes = 0;
    if (bytes === 0) return "0 B";
    if (decimals === undefined) decimals = 1;

    var k = 1024;
    var dm = decimals < 0 ? 0 : decimals;
    var sizes = ["B", "KB", "MB", "GB", "TB", "PB"];
    var i = Math.floor(Math.log(Math.abs(bytes)) / Math.log(k));
    if (i >= sizes.length) i = sizes.length - 1;
    if (i < 0) i = 0;

    var val = parseFloat((bytes / Math.pow(k, i)).toFixed(dm));
    return val + " " + sizes[i];
}

// Format rate values (bytes/sec) into human-readable strings (e.g. 4.2 MB/s, 310 KB/s)
function formatRate(bytesPerSec) {
    if (bytesPerSec === undefined || bytesPerSec === null || isNaN(bytesPerSec)) bytesPerSec = 0;
    return formatBytes(bytesPerSec, 1) + "/s";
}

// Map category to high-signal icons / symbols
function categoryIcon(category) {
    switch (category) {
        case "update": return "📦";
        case "container": return "🐳";
        case "app": return "🌐";
        case "cli": return "⚡";
        case "system": return "⚙️";
        default: return "💻";
    }
}

// Parse relative or ISO date ranges into { startTs, endTs } Unix epoch seconds
function resolveTimeRange(rangeKey, customFromStr, customToStr) {
    var now = Math.floor(Date.now() / 1000);
    var key = (rangeKey || "").toUpperCase();

    switch (key) {
        case "LIVE":
            return { startTs: now - 120, endTs: now, isLive: true, tierTable: "live_state" };
        case "24H":
            return { startTs: now - 86400, endTs: now, isLive: false, tierTable: "rollup_5min" };
        case "2D":
            return { startTs: now - (2 * 86400), endTs: now, isLive: false, tierTable: "rollup_5min" };
        case "7D":
            return { startTs: now - (7 * 86400), endTs: now, isLive: false, tierTable: "rollup_5min" };
        case "30D":
            return { startTs: now - (30 * 86400), endTs: now, isLive: false, tierTable: "rollup_1hour" };
        default:
            // Custom or shorthand expression
            var parsed = parseCustomRange(customFromStr, customToStr, now);
            return parsed;
    }
}

// Parse free-form offset strings like "-36h", "-14d", "-3w", "this-month" or ISO dates
function parseCustomRange(fromStr, toStr, nowSec) {
    if (!nowSec) nowSec = Math.floor(Date.now() / 1000);
    var startTs = nowSec - 86400;
    var endTs = nowSec;

    if (fromStr) {
        var str = fromStr.trim().toLowerCase();
        var matchOffset = str.match(/^-?(\d+)\s*([hdw])$/);
        if (matchOffset) {
            var num = parseInt(matchOffset[1], 10);
            var unit = matchOffset[2];
            var sec = 3600;
            if (unit === "h") sec = 3600;
            else if (unit === "d") sec = 86400;
            else if (unit === "w") sec = 7 * 86400;
            startTs = nowSec - (num * sec);
        } else if (str === "this-month") {
            var d = new Date();
            var monthStart = new Date(d.getFullYear(), d.getMonth(), 1);
            startTs = Math.floor(monthStart.getTime() / 1000);
        } else {
            var parsedDate = Date.parse(fromStr);
            if (!isNaN(parsedDate)) {
                startTs = Math.floor(parsedDate / 1000);
            }
        }
    }

    if (toStr) {
        var parsedEndDate = Date.parse(toStr);
        if (!isNaN(parsedEndDate)) {
            endTs = Math.floor(parsedEndDate / 1000);
        }
    }

    if (startTs > endTs) {
        var tmp = startTs;
        startTs = endTs;
        endTs = tmp;
    }

    var duration = endTs - startTs;
    var tierTable = duration <= (7 * 86400) ? "rollup_5min" : "rollup_1hour";

    return {
        startTs: startTs,
        endTs: endTs,
        isLive: false,
        tierTable: tierTable
    };
}

// Generate parameterized SQL command line for sqlite3 --json
function buildTreeQuery(dbPath, rangeInfo, filterText, sortBy) {
    var table = rangeInfo.tierTable;
    var whereParts = [];
    var params = [];

    if (rangeInfo.isLive) {
        whereParts.push("1=1");
    } else {
        whereParts.push("bucket_ts >= " + rangeInfo.startTs);
        whereParts.push("bucket_ts <= " + rangeInfo.endTs);
    }

    if (filterText && filterText.trim().length > 0) {
        var escaped = filterText.trim().replace(/'/g, "''");
        whereParts.push("(root_group LIKE '%" + escaped + "%' OR child_comm LIKE '%" + escaped + "%' OR child_detail LIKE '%" + escaped + "%')");
    }

    var whereSql = whereParts.join(" AND ");

    var orderClause = "total_bytes DESC";
    if (sortBy === "rx") orderClause = "rx_bytes DESC";
    else if (sortBy === "tx") orderClause = "tx_bytes DESC";

    if (rangeInfo.isLive) {
        return "SELECT root_group, category, child_comm, child_detail, CAST(rx_rate AS INTEGER) as rx_bytes, CAST(tx_rate AS INTEGER) as tx_bytes, CAST((rx_rate + tx_rate) AS INTEGER) as total_bytes FROM live_state WHERE " + whereSql + " ORDER BY " + orderClause + ";";
    }

    return "SELECT root_group, category, child_comm, child_detail, SUM(rx_bytes) AS rx_bytes, SUM(tx_bytes) AS tx_bytes, SUM(rx_bytes + tx_bytes) AS total_bytes FROM " + table + " WHERE " + whereSql + " GROUP BY root_group, category, child_comm, child_detail ORDER BY " + orderClause + ";";
}

// Generate query for the sparkline / time-brush histogram
function buildHistogramQuery(dbPath, rangeInfo) {
    if (rangeInfo.isLive) {
        return "SELECT updated_at AS bucket_ts, CAST(rx_rate AS INTEGER) AS rx, CAST(tx_rate AS INTEGER) AS tx FROM live_summary WHERE id=1;";
    }

    var table = rangeInfo.tierTable;
    return "SELECT bucket_ts, SUM(rx_bytes) AS rx, SUM(tx_bytes) AS tx, SUM(rx_bytes + tx_bytes) AS total FROM " + table + " WHERE bucket_ts >= " + rangeInfo.startTs + " AND bucket_ts <= " + rangeInfo.endTs + " GROUP BY bucket_ts ORDER BY bucket_ts ASC;";
}

// Process raw sqlite3 json output into aggregated parent-child hierarchy
function processRowsToTree(rows, totalWindowBytes) {
    if (!rows || !Array.isArray(rows) || rows.length === 0) {
        return { groups: [], windowRx: 0, windowTx: 0, windowTotal: 0 };
    }

    var groupMap = {};
    var windowRx = 0;
    var windowTx = 0;
    var maxGroupTotal = 1;

    for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        var rg = r.root_group || "Unknown";
        var cat = r.category || "cli";
        var rx = parseInt(r.rx_bytes || 0, 10);
        var tx = parseInt(r.tx_bytes || 0, 10);
        var tot = rx + tx;

        windowRx += rx;
        windowTx += tx;

        if (!groupMap[rg]) {
            groupMap[rg] = {
                rootGroup: rg,
                category: cat,
                rxBytes: 0,
                txBytes: 0,
                totalBytes: 0,
                children: []
            };
        }

        groupMap[rg].rxBytes += rx;
        groupMap[rg].txBytes += tx;
        groupMap[rg].totalBytes += tot;

        if (r.child_comm) {
            groupMap[rg].children.push({
                comm: r.child_comm,
                detail: r.child_detail || "",
                rxBytes: rx,
                txBytes: tx,
                totalBytes: tot
            });
        }
    }

    var windowTotal = windowRx + windowTx;
    if (windowTotal <= 0) windowTotal = 1;

    var groups = [];
    for (var key in groupMap) {
        var g = groupMap[key];
        if (g.totalBytes > maxGroupTotal) {
            maxGroupTotal = g.totalBytes;
        }
        groups.push(g);
    }

    // Sort parent groups by totalBytes descending
    groups.sort(function(a, b) {
        return b.totalBytes - a.totalBytes;
    });

    // Compute proportional shares
    for (var j = 0; j < groups.length; j++) {
        var item = groups[j];
        item.percentOfWindow = Math.min(100.0, (item.totalBytes / windowTotal) * 100.0);
        item.relativeBarShare = Math.min(1.0, item.totalBytes / maxGroupTotal);
        item.rxProportion = item.totalBytes > 0 ? (item.rxBytes / item.totalBytes) : 0;
        item.txProportion = item.totalBytes > 0 ? (item.txBytes / item.totalBytes) : 0;

        // Sort children inside each group
        item.children.sort(function(ca, cb) {
            return cb.totalBytes - ca.totalBytes;
        });
    }

    return {
        groups: groups,
        windowRx: windowRx,
        windowTx: windowTx,
        windowTotal: windowTotal
    };
}
