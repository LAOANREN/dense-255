using Toybox.Application as App;
using Toybox.Graphics as Gfx;
using Toybox.System as Sys;
using Toybox.Time as Time;
using Toybox.Time.Gregorian as Gregorian;
using Toybox.WatchUi as Ui;
using Toybox.Activity as Act;
using Toybox.ActivityMonitor as AM;
using Toybox.Weather as Weather;
using Toybox.Math as Math;

// Standard Forerunner 255, 260 x 260 MIP. No external image resources.
// Daily metrics come from ActivityMonitor; altitude/pressure/heading from Activity.
class KnightFace extends Ui.WatchFace {
    var _awake = false;
    var _wakeStart = -1;
    var _stamp = -1;
    var _weatherStamp = -1;
    var _daily = null;
    var _weather = null;
    var _historyHeart = null;
    var _heart = null;
    var _altitude = null;
    var _pressure = null;
    var _battery = null;
    var _phone = false;

    var _cn = true;
    var _accent = 0x00FFFF;
    var _hours24 = true;
    var _seconds = true;
    var _lines = true;
    // Fixed grid, read left to right: steps/altitude, distance/calories, HR/pressure.
    var _slots = [1, 13, 2, 3, 4, 12, 7, 8];

    var _headingCandidate = null;
    var _headingChangedAt = -1;
    var _headingDegrees = null;

    // Compact seven-row glyphs. Numbers are normally 14 px high; units 7 px.
    // This keeps full values and units inside the narrow bottom circular rows.
    var _glyphs = {
        "0" => [4, 6, 9, 9, 9, 9, 9, 6],
        "1" => [4, 2, 6, 2, 2, 2, 2, 7],
        "2" => [4, 6, 9, 1, 2, 4, 8, 15],
        "3" => [4, 14, 1, 1, 6, 1, 1, 14],
        "4" => [4, 2, 6, 10, 10, 15, 2, 2],
        "5" => [4, 15, 8, 8, 14, 1, 1, 14],
        "6" => [4, 6, 8, 8, 14, 9, 9, 6],
        "7" => [4, 15, 1, 1, 2, 2, 4, 4],
        "8" => [4, 6, 9, 9, 6, 9, 9, 6],
        "9" => [4, 6, 9, 9, 7, 1, 1, 6],
        "." => [1, 0, 0, 0, 0, 0, 1, 1],
        ":" => [1, 0, 1, 1, 0, 1, 1, 0],
        "-" => [3, 0, 0, 0, 7, 0, 0, 0],
        "/" => [3, 1, 1, 2, 2, 2, 4, 4],
        "%" => [5, 17, 18, 2, 4, 8, 9, 17],
        " " => [2, 0, 0, 0, 0, 0, 0, 0],
        "C" => [4, 7, 8, 8, 8, 8, 8, 7],
        "E" => [4, 15, 8, 8, 14, 8, 8, 15],
        "N" => [5, 17, 25, 25, 21, 19, 19, 17],
        "S" => [4, 7, 8, 8, 6, 1, 1, 14],
        "W" => [5, 17, 17, 17, 21, 21, 21, 10],
        "P" => [4, 14, 9, 9, 14, 8, 8, 8],
        "a" => [3, 0, 0, 6, 1, 7, 5, 7],
        "b" => [3, 4, 4, 6, 5, 5, 5, 6],
        "c" => [3, 0, 0, 3, 4, 4, 4, 3],
        "h" => [3, 4, 4, 6, 5, 5, 5, 5],
        "k" => [3, 4, 4, 5, 6, 6, 5, 5],
        "l" => [1, 1, 1, 1, 1, 1, 1, 1],
        "m" => [5, 0, 0, 26, 21, 21, 21, 21],
        "p" => [3, 0, 0, 6, 5, 6, 4, 4],
        "s" => [3, 0, 0, 3, 4, 2, 1, 6]
    };

    function initialize() {
        WatchFace.initialize();
        loadSettings();
    }

    function property(key, fallback) {
        var value = null;
        try {
            value = App.Properties.getValue(key);
        } catch (error) {
            return fallback;
        }
        return value == null ? fallback : value;
    }

    function loadSettings() {
        _cn = property("chinese", true);
        _hours24 = property("hours24", true);
        _seconds = property("showSeconds", true);
        _lines = property("showLines", true);
        var colors = [0x00FFFF, Gfx.COLOR_YELLOW, Gfx.COLOR_GREEN, Gfx.COLOR_WHITE];
        var index = property("accentColor", 0);
        if (index < 0 || index > 3) {
            index = 0;
        }
        _accent = colors[index];
        _stamp = -1;
        _weatherStamp = -1;
    }

    function onShow() {
        _stamp = -1;
        _weatherStamp = -1;
    }

    function resetHeading() {
        _headingCandidate = null;
        _headingChangedAt = -1;
        _headingDegrees = null;
    }

    function onHide() {
        _awake = false;
        _wakeStart = -1;
        resetHeading();
    }

    function onEnterSleep() {
        _awake = false;
        _wakeStart = -1;
        resetHeading();
        Ui.requestUpdate();
    }

    function onExitSleep() {
        _awake = true;
        _wakeStart = Time.now().value();
        _stamp = -1;
        _weatherStamp = -1;
        resetHeading();
        Ui.requestUpdate();
    }

    function words(cn, en) {
        return _cn ? cn : en;
    }

    function integer(value) {
        return value == null ? "--" : Math.round(value).toNumber().toString();
    }

    function decimal(value) {
        return value == null ? "--" : (value * 1.0).format("%.1f");
    }

    function two(value) {
        return value.format("%02d");
    }

    function readDaily(now) {
        var interval = _awake ? 5 : 60;
        if (_stamp != -1 && now >= _stamp && now - _stamp < interval) {
            return;
        }
        _stamp = now;
        _daily = AM.getInfo();
        _battery = Sys.getSystemStats().battery;
        _historyHeart = null;
        var iterator = AM.getHeartRateHistory(new Time.Duration(300), true);
        for (var i = 0; i < 5; i += 1) {
            var sample = iterator.next();
            if (sample == null) {
                break;
            }
            if (sample.heartRate != null && sample.heartRate > 0 && sample.heartRate < 255) {
                _historyHeart = sample.heartRate;
                break;
            }
        }
    }

    function updateHeading(radians, now) {
        if (!_awake || radians == null) {
            resetHeading();
            return;
        }
        // Reject invalid numbers and normalize wraparound before comparison.
        if (!(radians >= -2.0 * Math.PI && radians <= 2.0 * Math.PI)) {
            resetHeading();
            return;
        }
        var degrees = radians * 180.0 / Math.PI;
        if (degrees < 0) {
            degrees += 360.0;
        }
        if (degrees >= 360.0) {
            degrees -= 360.0;
        }

        // Activity.Info has no heading sample timestamp. Polling the same
        // cached value is NOT evidence of a live compass. Require an observed
        // change and expire it after 5 seconds; a stationary watch can show --.
        if (_headingCandidate != null) {
            var difference = degrees - _headingCandidate;
            if (difference < 0) {
                difference = -difference;
            }
            if (difference > 180.0) {
                difference = 360.0 - difference;
            }
            if (difference >= 0.5) {
                _headingChangedAt = now;
            }
        }
        _headingCandidate = degrees;
        if (_headingChangedAt >= 0 && now >= _headingChangedAt && now - _headingChangedAt <= 5) {
            _headingDegrees = Math.round(degrees).toNumber() % 360;
        } else {
            _headingDegrees = null;
        }
    }

    function refreshData(now) {
        var connected = Sys.getDeviceSettings().phoneConnected == true;
        if (connected != _phone) {
            _phone = connected;
            _weather = null;
            _weatherStamp = -1;
        }
        readDaily(now);

        var activity = Act.getActivityInfo();
        _heart = _historyHeart;
        _altitude = null;
        _pressure = null;
        var heading = null;
        if (activity != null) {
            if (activity.currentHeartRate != null && activity.currentHeartRate > 0 && activity.currentHeartRate < 255) {
                _heart = activity.currentHeartRate;
            }
            if (_phone && activity.altitude != null) {
                _altitude = activity.altitude;
            }
            if ((activity has :ambientPressure) && activity.ambientPressure != null && activity.ambientPressure > 0) {
                _pressure = activity.ambientPressure / 100.0;
            }
            heading = activity.currentHeading;
        }
        updateHeading(heading, now);

        if (!_phone) {
            _weather = null;
            return;
        }
        var ready = _weather != null &&
            (_weather.temperature != null || _weather.windSpeed != null || _weather.relativeHumidity != null);
        var interval = ready ? 600 : 60;
        if (_weatherStamp == -1 || now < _weatherStamp || now - _weatherStamp >= interval) {
            _weather = Weather.getCurrentConditions();
            _weatherStamp = now;
        }
    }

    function safeRowWidth(dc, top, height) {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var diameter = w < h ? w : h;
        var radius = diameter / 2.0 - 5.0;
        var d1 = top - h / 2.0;
        var d2 = top + height - h / 2.0;
        if (d1 < 0) { d1 = -d1; }
        if (d2 < 0) { d2 = -d2; }
        var distance = d1 > d2 ? d1 : d2;
        if (distance >= radius) { return 0; }
        return (2.0 * Math.sqrt(radius * radius - distance * distance) - 6.0).toNumber();
    }

    function glyph(character) {
        var shape = _glyphs[character];
        return shape == null ? _glyphs["-"] : shape;
    }

    function compactWidth(value, scale) {
        if (value.length() == 0) { return 0; }
        var width = 0;
        for (var i = 0; i < value.length(); i += 1) {
            width += (glyph(value.substring(i, i + 1))[0] + 1) * scale;
        }
        return width - scale;
    }

    function drawCompact(dc, x, y, value, scale, color) {
        dc.setColor(color, Gfx.COLOR_BLACK);
        for (var i = 0; i < value.length(); i += 1) {
            var shape = glyph(value.substring(i, i + 1));
            var width = shape[0];
            for (var row = 0; row < 7; row += 1) {
                var bits = shape[row + 1];
                for (var col = 0; col < width; col += 1) {
                    if ((bits & (1 << (width - col - 1))) != 0) {
                        dc.fillRectangle(x + col * scale, y + row * scale, scale, scale);
                    }
                }
            }
            x += (width + 1) * scale;
        }
    }

    function centeredText(dc, top, height, candidates, color, compactFallback) {
        var font = Gfx.FONT_XTINY;
        var width = safeRowWidth(dc, top, height) - 4;
        var centerX = (dc.getWidth() / 2).toNumber();
        for (var i = 0; i < candidates.size(); i += 1) {
            if (dc.getTextWidthInPixels(candidates[i], font) <= width && dc.getFontHeight(font) <= height) {
                dc.setColor(color, Gfx.COLOR_BLACK);
                dc.drawText(centerX, top + ((height - dc.getFontHeight(font)) / 2).toNumber(),
                    font, candidates[i], Gfx.TEXT_JUSTIFY_CENTER);
                return;
            }
        }
        // Numeric fallback keeps complete values and units, never substrings.
        var scale = 2;
        if (compactWidth(compactFallback, scale) > width || 7 * scale > height) {
            scale = 1;
        }
        if (compactWidth(compactFallback, scale) <= width) {
            drawCompact(dc, centerX - (compactWidth(compactFallback, scale) / 2).toNumber(),
                top + ((height - 7 * scale) / 2).toNumber(), compactFallback, scale, color);
        }
    }

    function weatherName() {
        if (_weather == null || _weather.condition == null) { return words("天气", "WX"); }
        var c = _weather.condition;
        if (c == 0 || c == 22 || c == 23 || c == 40) { return words("晴", "CLR"); }
        if (c == 1 || c == 2 || c == 20 || c == 52) { return words("云", "CLD"); }
        if (c == 6 || c == 12 || c == 28) { return words("雷雨", "TSTM"); }
        if (c == 4 || c == 16 || c == 17 || c == 43 || c == 46 || c == 48) { return words("雪", "SNOW"); }
        if (c == 3 || c == 11 || c == 14 || c == 15 || c == 24 || c == 25 || c == 26 || c == 27 || c == 31 || c == 45) { return words("雨", "RAIN"); }
        if (c == 8 || c == 9 || c == 29 || c == 39) { return words("雾", "FOG"); }
        if (c == 5) { return words("风", "WIND"); }
        return words("天气", "WX");
    }

    function drawWeather(dc, top, rowHeight) {
        var temperature = "--";
        var range = "--";
        var wind = "--";
        var humidity = "--";
        if (_phone && _weather != null) {
            if (_weather.temperature != null) { temperature = integer(_weather.temperature) + "C"; }
            if (_weather.lowTemperature != null || _weather.highTemperature != null) {
                range = integer(_weather.lowTemperature) + "/" + integer(_weather.highTemperature) + "C";
            }
            if (_weather.windSpeed != null) { wind = decimal(_weather.windSpeed) + "m/s"; }
            if (_weather.relativeHumidity != null) { humidity = integer(_weather.relativeHumidity) + "%"; }
        }
        var compact = temperature + " " + range;
        centeredText(dc, top, rowHeight,
            [weatherName() + " " + compact, compact], Gfx.COLOR_WHITE, compact);
        var details = words("风 ", "W ") + wind + "  " + words("湿 ", "RH ") + humidity;
        centeredText(dc, top + rowHeight + 1, rowHeight,
            [details, wind + "  " + humidity], Gfx.COLOR_LT_GRAY, wind + " " + humidity);
    }

    function drawCompass(dc, left, top, width, height) {
        var color = _headingDegrees == null ? Gfx.COLOR_DK_GRAY : _accent;
        var arrowX = left + 10;
        var arrowY = top + 3;
        // The upward arrow means the direction in front of the watch (12 o'clock).
        // It is not a north-pointing needle and never uses weather wind bearing.
        dc.setColor(color, Gfx.COLOR_BLACK);
        dc.drawLine(arrowX, arrowY, arrowX, arrowY + 13);
        dc.drawLine(arrowX, arrowY, arrowX - 4, arrowY + 5);
        dc.drawLine(arrowX, arrowY, arrowX + 4, arrowY + 5);
        var number = integer(_headingDegrees);
        drawCompact(dc, left + 19, top + 6, number, 1, color);
        if (_headingDegrees != null) {
            dc.setColor(color, Gfx.COLOR_BLACK);
            dc.drawCircle(left + 20 + compactWidth(number, 1), top + 5, 1);
        }
        var label = "--";
        if (_headingDegrees != null) {
            var names = _cn
                ? ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
                : ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];
            label = names[((_headingDegrees + 22.5) / 45.0).toNumber() % 8];
        }
        var font = Gfx.FONT_XTINY;
        if (height >= dc.getFontHeight(font) + 19) {
            dc.setColor(color, Gfx.COLOR_BLACK);
            dc.drawText(left + (width / 2).toNumber(), top + height - dc.getFontHeight(font),
                font, label, Gfx.TEXT_JUSTIFY_CENTER);
        } else {
            var shortLabel = "--";
            if (_headingDegrees != null) {
                var shortNames = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];
                shortLabel = shortNames[((_headingDegrees + 22.5) / 45.0).toNumber() % 8];
            }
            drawCompact(dc, left + ((width - compactWidth(shortLabel, 1)) / 2).toNumber(),
                top + height - 8, shortLabel, 1, color);
        }
    }

    function drawClock(dc, clock, top, height) {
        var centerX = (dc.getWidth() / 2).toNumber();
        var rowWidth = safeRowWidth(dc, top, height);
        var left = centerX - (rowWidth / 2).toNumber();
        var compassWidth = 46;
        drawCompass(dc, left, top, compassWidth, height);
        var clockLeft = left + compassWidth + 5;
        var clockWidth = rowWidth - compassWidth - 5;
        var hour = clock.hour;
        if (!_hours24) {
            hour = hour % 12;
            if (hour == 0) { hour = 12; }
        }
        var value = two(hour) + ":" + two(clock.min);
        var scale = (height / 7).toNumber();
        if (scale > 7) { scale = 7; }
        while (scale > 1 && compactWidth(value, scale) > clockWidth) { scale -= 1; }
        drawCompact(dc, clockLeft + ((clockWidth - compactWidth(value, scale)) / 2).toNumber(),
            top + ((height - 7 * scale) / 2).toNumber(), value, scale, _accent);
    }

    function drawDate(dc, date, clock, top, height) {
        var week = _cn
            ? ["日", "一", "二", "三", "四", "五", "六"]
            : ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];
        var base = two(date.month) + "/" + two(date.day) + " " + words("周", "") + week[date.day_of_week - 1];
        var standard = base;
        if (!_hours24) { standard += clock.hour < 12 ? " AM" : " PM"; }
        var detail = standard;
        if (_seconds && _awake) { detail += " " + two(clock.sec) + "s"; }
        centeredText(dc, top, height, [detail, standard, base], _accent, two(date.month) + "/" + two(date.day));
    }

    function numberMetric(value, unit) {
        return [integer(value), value == null ? "" : unit];
    }

    function metricValue(id) {
        if (id == 4) { return numberMetric(_heart, "bpm"); }
        if (id == 8) { return numberMetric(_battery, "%"); }
        if (id == 12) { return numberMetric(_pressure, "hPa"); }
        if (id == 13) { return numberMetric(_altitude, "m"); }
        if (id == 9) { return numberMetric(_weather == null ? null : _weather.relativeHumidity, "%"); }
        if (id == 10) {
            var wind = _weather == null ? null : _weather.windSpeed;
            return [decimal(wind), wind == null ? "" : "m/s"];
        }
        if (id == 11) { return numberMetric(_weather == null ? null : _weather.temperature, "C"); }
        if (_daily == null) { return ["--", ""]; }
        if (id == 1) { return numberMetric(_daily.steps, ""); }
        if (id == 2) {
            var km = _daily.distance == null ? null : _daily.distance / 100000.0;
            return [decimal(km), km == null ? "" : "km"];
        }
        if (id == 3) { return numberMetric(_daily.calories, "kcal"); }
        if (id == 5) { return numberMetric(_daily.floorsClimbed, ""); }
        if (id == 6) {
            var active = null;
            if (_daily.activeMinutesDay != null) {
                var minutes = _daily.activeMinutesDay;
                if (minutes.moderate != null && minutes.vigorous != null) {
                    active = minutes.moderate + 2 * minutes.vigorous;
                }
            }
            return numberMetric(active, "");
        }
        if (id == 7) {
            var goal = null;
            if (_daily.steps != null && _daily.stepGoal != null && _daily.stepGoal > 0) {
                goal = _daily.steps * 100.0 / _daily.stepGoal;
            }
            return numberMetric(goal, "%");
        }
        return ["--", ""];
    }

    function metricLabel(id, shortened) {
        if (id == 1) { return shortened ? words("步", "S") : words("步数", "STP"); }
        if (id == 2) { return shortened ? words("距", "D") : words("距离", "DIST"); }
        if (id == 3) { return shortened ? words("热", "C") : words("热量", "CAL"); }
        if (id == 4) { return shortened ? words("心", "H") : words("心率", "HR"); }
        if (id == 5) { return shortened ? words("层", "F") : words("楼层", "FLR"); }
        if (id == 6) { return shortened ? words("强", "I") : words("强度", "INT"); }
        if (id == 7) { return shortened ? words("标", "G") : words("目标", "GOAL"); }
        if (id == 8) { return shortened ? words("电", "B") : words("电量", "BAT"); }
        if (id == 9) { return shortened ? words("湿", "H") : words("湿度", "HUM"); }
        if (id == 10) { return shortened ? words("风", "W") : words("风速", "WIND"); }
        if (id == 11) { return shortened ? words("温", "T") : words("气温", "TEMP"); }
        if (id == 12) { return shortened ? words("压", "P") : words("气压", "BARO"); }
        if (id == 13) { return shortened ? words("高", "A") : words("海拔", "ALT"); }
        return "";
    }

    function dataCell(dc, x, y, width, height, id) {
        var parts = metricValue(id);
        var value = parts[0];
        var unit = parts[1];
        var font = Gfx.FONT_XTINY;
        var scale = 2;
        var gap = unit.length() == 0 ? 0 : 2;
        var unitWidth = compactWidth(unit, 1);
        var valueWidth = compactWidth(value, scale) + gap + unitWidth;
        var shortLabel = metricLabel(id, true);
        if (dc.getTextWidthInPixels(shortLabel, font) + valueWidth + 7 > width) {
            scale = 1;
            valueWidth = compactWidth(value, scale) + gap + unitWidth;
        }
        var label = metricLabel(id, false);
        if (dc.getTextWidthInPixels(label, font) + valueWidth + 7 > width) {
            label = shortLabel;
        }
        // Keep the value intact even for exceptionally large daily totals.
        if (dc.getTextWidthInPixels(label, font) + valueWidth + 7 > width) {
            value = "--";
            unit = "";
            unitWidth = 0;
            gap = 0;
            valueWidth = compactWidth(value, scale);
        }
        dc.setClip(x, y, width, height);
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_BLACK);
        dc.drawText(x + 2, y + ((height - dc.getFontHeight(font)) / 2).toNumber(),
            font, label, Gfx.TEXT_JUSTIFY_LEFT);
        var valueX = x + width - 2 - valueWidth;
        var valueY = y + ((height - 7 * scale) / 2).toNumber();
        drawCompact(dc, valueX, valueY, value, scale, Gfx.COLOR_WHITE);
        if (unit.length() > 0) {
            drawCompact(dc, valueX + compactWidth(value, scale) + gap,
                valueY + 7 * scale - 7, unit, 1, Gfx.COLOR_LT_GRAY);
        }
        dc.clearClip();
    }

    function drawGrid(dc, top, rowHeight) {
        var centerX = (dc.getWidth() / 2).toNumber();
        for (var row = 0; row < 3; row += 1) {
            var y = top + row * rowHeight;
            var width = safeRowWidth(dc, y, rowHeight);
            var cellWidth = ((width - 6) / 2).toNumber();
            dataCell(dc, centerX - 3 - cellWidth, y, cellWidth, rowHeight, _slots[row * 2]);
            dataCell(dc, centerX + 3, y, cellWidth, rowHeight, _slots[row * 2 + 1]);
            if (_lines && row < 2) {
                var lineY = y + rowHeight - 1;
                var half = (safeRowWidth(dc, lineY, 1) / 2).toNumber();
                dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_BLACK);
                dc.drawLine(centerX - half + 3, lineY, centerX + half - 3, lineY);
            }
        }
        if (_lines) {
            dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_BLACK);
            dc.drawLine(centerX, top + 1, centerX, top + rowHeight * 3 - 2);
        }
    }

    function drawBattery(dc, top, height, now) {
        var level = 0;
        if (_battery != null) {
            level = Math.round(_battery).toNumber();
            if (level < 0) { level = 0; }
            if (level > 100) { level = 100; }
        }
        var value = _battery == null ? "--" : level.toString() + "%";
        var totalWidth = 31 + compactWidth(value, 2);
        var x = ((dc.getWidth() - totalWidth) / 2).toNumber();
        var y = top + ((height - 12) / 2).toNumber();
        var color = _battery != null && level <= 15 ? Gfx.COLOR_RED : _accent;
        var elapsed = _wakeStart < 0 ? -1 : now - _wakeStart;
        if (_awake && elapsed >= 0 && elapsed < 3) {
            var padding = elapsed == 1 ? 3 : 2;
            dc.setColor(elapsed == 1 ? Gfx.COLOR_WHITE : color, Gfx.COLOR_BLACK);
            dc.drawRectangle(x - padding, y - padding, 22 + padding * 2, 12 + padding * 2);
        }
        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_BLACK);
        dc.drawRectangle(x, y, 22, 12);
        dc.fillRectangle(x + 22, y + 4, 3, 4);
        if (_battery != null && level > 0) {
            var fill = (18 * level / 100.0).toNumber();
            if (fill > 0) {
                dc.setColor(color, Gfx.COLOR_BLACK);
                dc.fillRectangle(x + 2, y + 2, fill, 8);
            }
        }
        drawCompact(dc, x + 31, top + ((height - 14) / 2).toNumber(), value, 2, Gfx.COLOR_WHITE);
    }

    function onUpdate(dc) {
        var moment = Time.now();
        var now = moment.value();
        refreshData(now);
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();

        var smallHeight = dc.getFontHeight(Gfx.FONT_XTINY);
        if (smallHeight < 16) { smallHeight = 16; }
        var rowHeight = smallHeight + 3;
        // Footer uses the 14-pixel numeric glyphs, independent of system font height.
        var batteryHeight = 14;
        var batteryTop = dc.getHeight() - 20 - batteryHeight;
        var gridTop = batteryTop - 7 - rowHeight * 3;
        var dateTop = gridTop - smallHeight - 4;
        var weatherHeight = smallHeight > 22 ? 14 : smallHeight;
        var weatherTop = 28;
        var clockTop = weatherTop + weatherHeight * 2 + 4;
        var clockHeight = dateTop - 3 - clockTop;
        var clock = Sys.getClockTime();
        var date = Gregorian.info(moment, Time.FORMAT_SHORT);

        drawWeather(dc, weatherTop, weatherHeight);
        drawClock(dc, clock, clockTop, clockHeight);
        drawDate(dc, date, clock, dateTop, smallHeight);
        drawGrid(dc, gridTop, rowHeight);
        drawBattery(dc, batteryTop, batteryHeight, now);
        // Active-mode updates come from the watch once per second. No busy loop.
    }
}
