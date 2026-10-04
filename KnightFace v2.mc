using Toybox.Application as App;
using Toybox.Graphics as Gfx;
using Toybox.System as Sys;
using Toybox.Time as Time;
using Toybox.Time.Gregorian as Gregorian;
using Toybox.WatchUi as Ui;
using Toybox.ActivityMonitor as AM;
using Toybox.Weather as Weather;
using Toybox.Math as Math;

// Original watch face for the standard Forerunner 255.
// The approved lower layout is a fixed two-column, three-row data grid.
class KnightFace extends Ui.WatchFace {
    var _awake = true;
    var _stamp = -1;
    var _weatherStamp = -1;

    var _info = null;
    var _weather = null;
    var _heart = null;
    var _battery = null;
    var _phone = false;

    var _cn = true;
    var _accent = 0x00FFFF;
    var _slots = [1, 13, 2, 3, 4, 12, 7, 8];
    var _hours24 = true;
    var _seconds = true;
    var _lines = true;

    // Three-frame wake animation: normal, blink, then a one-pixel nod.
    var _animationFrame = 0;
    var _animating = false;

    function initialize() {
        WatchFace.initialize();
        loadSettings();
    }

    function property(key, fallback) {
        var value = App.Properties.getValue(key);
        return value == null ? fallback : value;
    }

    function loadSettings() {
        _cn = property("chinese", true);
        _hours24 = property("hours24", true);
        _seconds = property("showSeconds", true);
        _lines = property("showLines", true);

        var colors = [
            0x00FFFF,
            Gfx.COLOR_YELLOW,
            Gfx.COLOR_GREEN,
            Gfx.COLOR_WHITE
        ];

        var index = property("accentColor", 0);

        if (index < 0 || index > 3) {
            index = 0;
        }

        _accent = colors[index];

        // Keep the approved six-cell layout stable even when an older
        // installation has saved the previous slot values.
        var defaults = [1, 13, 2, 3, 4, 12, 7, 8];
        for (var i = 0; i < 8; i += 1) {
            _slots[i] = defaults[i];
        }

        _stamp = -1;
    }

    function onEnterSleep() {
        _awake = false;
        _animating = false;
        _animationFrame = 0;
    }

    function onExitSleep() {
        _awake = true;
        _animationFrame = 0;
        _animating = true;
        _stamp = -1;
        _weatherStamp = -1;
        Ui.requestUpdate();
    }

    function words(cn, en) {
        return _cn ? cn : en;
    }

    function integer(value) {
        if (value == null) {
            return "--";
        }

        return Math.round(value).toNumber().toString();
    }

    function decimal(value) {
        if (value == null) {
            return "--";
        }

        return (value * 1.0).format("%.1f");
    }

    function two(value) {
        return value.format("%02d");
    }

    function refreshData() {
        var minute = (Time.now().value() / 60).toNumber();

        if (_stamp == minute) {
            return;
        }

        _stamp = minute;
        _info = AM.getInfo();
        _battery = Sys.getSystemStats().battery;

        var wasPhoneConnected = _phone;
        _phone = Sys.getDeviceSettings().phoneConnected;

        // A newly restored phone connection means Garmin Connect may have
        // delivered a new weather cache. Force a read on the next pass.
        if (_phone != wasPhoneConnected) {
            _weatherStamp = -1;
        }

        _heart = null;

        // Read recent cached heart rate without activating the sensor.
        var iterator = AM.getHeartRateHistory(
            new Time.Duration(300),
            true
        );

        for (var j = 0; j < 5; j += 1) {
            var sample = iterator.next();

            if (sample == null) {
                break;
            }

            if (sample.heartRate != null &&
                sample.heartRate > 0 &&
                sample.heartRate < 255) {
                _heart = sample.heartRate;
                break;
            }
        }

        // Weather.getCurrentConditions() reads the most recent Garmin
        // Connect cache; it does not start a network request itself.
        // Retry empty or incomplete data sooner so a phone sync can
        // populate the cache.
        var weatherReady = _weather != null &&
            (_weather.temperature != null ||
             _weather.windSpeed != null ||
             _weather.relativeHumidity != null);
        var weatherInterval = weatherReady ? 10 : 1;

        if (_weatherStamp == -1 ||
            minute < _weatherStamp ||
            minute - _weatherStamp >= weatherInterval) {
            var cachedWeather = Weather.getCurrentConditions();

            if (cachedWeather != null) {
                _weather = cachedWeather;
            }

            _weatherStamp = minute;
        }
    }

    function text(dc, x, y, width, height, value, color, centered) {
        var font = Gfx.FONT_XTINY;
        var shown = value;

        while (shown.length() > 0 &&
               dc.getTextWidthInPixels(shown, font) > width) {
            shown = shown.substring(0, shown.length() - 1);
        }

        dc.setColor(color, Gfx.COLOR_BLACK);

        var textY = y +
            ((height - dc.getFontHeight(font)) / 2).toNumber();

        var textX = centered
            ? x + (width / 2).toNumber()
            : x;

        var alignment = centered
            ? Gfx.TEXT_JUSTIFY_CENTER
            : Gfx.TEXT_JUSTIFY_LEFT;

        dc.drawText(
            textX,
            textY,
            font,
            shown,
            alignment
        );
    }

    function metricLabel(id) {
        if (id == 1) {
            return words("步数", "STP");
        }

        if (id == 2) {
            return words("距离", "DIST");
        }

        if (id == 3) {
            return words("热量", "CAL");
        }

        if (id == 4) {
            return words("心率", "HR");
        }

        if (id == 5) {
            return words("楼层", "FLR");
        }

        if (id == 6) {
            return words("强度", "INT");
        }

        if (id == 7) {
            return words("目标", "GOAL");
        }

        if (id == 8) {
            return words("电量", "BAT");
        }

        if (id == 9) {
            return words("湿度", "HUM");
        }

        if (id == 10) {
            return words("风速", "WIND");
        }

        if (id == 11) {
            return words("气温", "TEMP");
        }

        if (id == 12) {
            return words("气压", "PRESS");
        }

        if (id == 13) {
            return words("海拔", "ALT");
        }

        return "";
    }

    function metricValue(id) {
        if (id == 0 || _info == null) {
            if (id == 8 && _battery != null) {
                return integer(_battery) + "%";
            }

            return "--";
        }

        if (id == 1) {
            return integer(_info.steps);
        }

        if (id == 2) {
            var km = _info.distance == null
                ? null
                : _info.distance / 100000.0;

            return decimal(km) + "km";
        }

        if (id == 3) {
            return integer(_info.calories) + "kcal";
        }

        if (id == 4) {
            return integer(_heart) + "bpm";
        }

        if (id == 5) {
            return integer(_info.floorsClimbed);
        }

        if (id == 6) {
            var active = null;

            if (_info.activeMinutesDay != null) {
                var minutes = _info.activeMinutesDay;

                if (minutes.moderate != null &&
                    minutes.vigorous != null) {
                    active = minutes.moderate +
                        2 * minutes.vigorous;
                }
            }

            return integer(active);
        }

        if (id == 7) {
            var percent = null;

            if (_info.steps != null &&
                _info.stepGoal != null &&
                _info.stepGoal > 0) {
                percent = _info.steps * 100.0 /
                    _info.stepGoal;
            }

            return integer(percent) + "%";
        }

        if (id == 8) {
            return integer(_battery) + "%";
        }

        if (id == 9) {
            var humidity = _weather == null
                ? null
                : _weather.relativeHumidity;

            return integer(humidity) + "%";
        }

        if (id == 10) {
            var wind = _weather == null
                ? null
                : _weather.windSpeed;

            return decimal(wind) + "m/s";
        }

        if (id == 11) {
            var temperature = _weather == null
                ? null
                : _weather.temperature;

            return integer(temperature) + "C";
        }

        if (id == 12) {
            var pressure = null;

            if (_weather != null &&
                _weather.pressure != null) {
                pressure = _weather.pressure / 100.0;
            }

            return integer(pressure) + "hPa";
        }

        if (id == 13) {
            // ActivityMonitor exposes the available climbed-elevation value
            // on this target. It is presented as 海拔 in the approved layout.
            return integer(_info.metersClimbed) + "m";
        }

        return "--";
    }

    function dataCell(dc, x, y, width, id) {
        var label = metricLabel(id);
        var value = metricValue(id);
        var font = Gfx.FONT_XTINY;
        var rowHeight = 21;
        var gap = 3;
        var valueWidth = dc.getTextWidthInPixels(value, font);
        var labelWidth = width - valueWidth - gap;
        var shownLabel = label;

        if (labelWidth < 0) {
            labelWidth = 0;
        }

        while (shownLabel.length() > 0 &&
               dc.getTextWidthInPixels(shownLabel, font) > labelWidth) {
            shownLabel = shownLabel.substring(
                0,
                shownLabel.length() - 1
            );
        }

        var textY = y +
            ((rowHeight - dc.getFontHeight(font)) / 2).toNumber();

        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_BLACK);
        dc.drawText(
            x + 2,
            textY,
            font,
            shownLabel,
            Gfx.TEXT_JUSTIFY_LEFT
        );

        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.drawText(
            x + width - 2,
            textY,
            font,
            value,
            Gfx.TEXT_JUSTIFY_RIGHT
        );
    }

    function drawBattery(dc, x, y, percent) {
        var level = percent == null ? 0 : percent;

        if (level < 0) {
            level = 0;
        }

        if (level > 100) {
            level = 100;
        }

        var fill = (12 * level / 100).toNumber();

        dc.setColor(Gfx.COLOR_LT_GRAY, Gfx.COLOR_BLACK);
        dc.drawLine(x, y, x + 14, y);
        dc.drawLine(x, y + 8, x + 14, y + 8);
        dc.drawLine(x, y, x, y + 8);
        dc.drawLine(x + 14, y, x + 14, y + 8);
        dc.drawLine(x + 15, y + 2, x + 17, y + 2);
        dc.drawLine(x + 15, y + 6, x + 17, y + 6);

        if (fill > 0) {
            dc.setColor(_accent, Gfx.COLOR_BLACK);
            dc.fillRectangle(x + 2, y + 2, fill, 5);
        }
    }

    // A compact pixel-style portrait of Eliud Kipchoge. The three frames
    // close the eyes and then move the head down by one pixel.
    function drawKipchogeAvatar(dc, cx, cy, frame) {
        var nod = frame == 2 ? 1 : 0;
        var skin = 0x6B3F2A;
        var skinLight = 0x986548;
        var hair = 0x151515;
        var shirt = Gfx.COLOR_WHITE;
        var kitRed = 0xD62828;
        var kitGreen = 0x168B45;

        // Athletic shoulders and a simple red/green running-kit accent.
        dc.setColor(shirt, Gfx.COLOR_BLACK);
        dc.fillCircle(cx, cy + 5, 10);
        dc.fillRectangle(cx - 9, cy + 4, 18, 9);
        dc.setColor(kitRed, Gfx.COLOR_BLACK);
        dc.drawLine(cx - 8, cy + 3, cx + 8, cy + 3);
        dc.setColor(kitGreen, Gfx.COLOR_BLACK);
        dc.drawLine(cx - 6, cy + 6, cx + 6, cy + 6);

        // Face, ears and close-cropped hair.
        dc.setColor(skin, Gfx.COLOR_BLACK);
        dc.fillCircle(cx - 6, cy - 7 + nod, 2);
        dc.fillCircle(cx + 6, cy - 7 + nod, 2);
        dc.fillCircle(cx, cy - 7 + nod, 6);

        dc.setColor(skinLight, Gfx.COLOR_BLACK);
        dc.fillCircle(cx + 2, cy - 6 + nod, 4);

        dc.setColor(hair, Gfx.COLOR_BLACK);
        dc.drawLine(cx - 4, cy - 11 + nod, cx + 4, cy - 11 + nod);
        dc.drawLine(cx - 4, cy - 10 + nod, cx - 2, cy - 12 + nod);
        dc.drawLine(cx - 1, cy - 11 + nod, cx + 1, cy - 12 + nod);
        dc.drawLine(cx + 2, cy - 11 + nod, cx + 4, cy - 10 + nod);

        dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_BLACK);

        if (frame == 1) {
            dc.drawLine(cx - 3, cy - 7 + nod, cx - 1, cy - 7 + nod);
            dc.drawLine(cx + 1, cy - 7 + nod, cx + 3, cy - 7 + nod);
        } else {
            dc.fillCircle(cx - 2, cy - 7 + nod, 1);
            dc.fillCircle(cx + 2, cy - 7 + nod, 1);
        }

        // Nose and the broad smile used for the compact portrait.
        dc.drawLine(cx, cy - 6 + nod, cx, cy - 4 + nod);
        dc.drawLine(cx - 2, cy - 3 + nod, cx + 2, cy - 3 + nod);
    }

    function drawBottomStatus(dc, width, height) {
        var centerX = (width / 2).toNumber();
        var frame = _animating ? _animationFrame : 0;
        var baseY = height - 18;

        drawKipchogeAvatar(dc, centerX - 26, baseY, frame);
        drawBattery(dc, centerX - 12, height - 22, _battery);

        text(
            dc,
            centerX + 9,
            height - 26,
            36,
            18,
            integer(_battery) + "%",
            Gfx.COLOR_WHITE,
            false
        );
    }

    function onUpdate(dc) {
        refreshData();

        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();

        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = (width / 2).toNumber();

        var clock = Sys.getClockTime();
        var date = Gregorian.info(
            Time.now(),
            Time.FORMAT_SHORT
        );

        var week = _cn
            ? ["日", "一", "二", "三", "四", "五", "六"]
            : ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];

        var temperature = _weather == null
            ? null
            : _weather.temperature;

        var high = _weather == null
            ? null
            : _weather.highTemperature;

        var low = _weather == null
            ? null
            : _weather.lowTemperature;

        // The upper half remains from the previous approved design.
        text(
            dc,
            45,
            24,
            width - 90,
            21,
            words("气温 ", "TEMP ") +
                integer(temperature) + "C  " +
                integer(low) + "/" + integer(high),
            Gfx.COLOR_WHITE,
            true
        );

        var wind = _weather == null
            ? null
            : _weather.windSpeed;

        var humidity = _weather == null
            ? null
            : _weather.relativeHumidity;

        text(
            dc,
            26,
            46,
            width - 52,
            19,
            words("风 ", "WIND ") +
                decimal(wind) + "m/s  " +
                words("湿 ", "RH ") +
                integer(humidity) + "%",
            Gfx.COLOR_LT_GRAY,
            true
        );

        text(
            dc,
            24,
            66,
            width - 48,
            19,
            two(date.month) + "/" + two(date.day) +
                "  " + words("周", "") +
                week[date.day_of_week - 1],
            _accent,
            true
        );

        if (_lines) {
            dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_BLACK);
            dc.drawLine(29, 86, width - 29, 86);
        }

        var hour = clock.hour;

        if (!_hours24) {
            hour = hour % 12;

            if (hour == 0) {
                hour = 12;
            }
        }

        var timeText = two(hour) + ":" + two(clock.min);
        var timeFont = Gfx.FONT_NUMBER_HOT;

        if (dc.getTextWidthInPixels(timeText, timeFont) >
                width - 38 ||
            dc.getFontHeight(timeFont) > 43) {
            timeFont = Gfx.FONT_NUMBER_MEDIUM;
        }

        dc.setColor(_accent, Gfx.COLOR_BLACK);

        dc.drawText(
            centerX,
            88 + ((43 - dc.getFontHeight(timeFont)) / 2).toNumber(),
            timeFont,
            timeText,
            Gfx.TEXT_JUSTIFY_CENTER
        );

        var status = _phone
            ? words("已连接", "LINK")
            : words("未连接", "OFFLINE");

        if (!_hours24) {
            status += clock.hour < 12 ? " AM" : " PM";
        }

        if (_seconds && _awake) {
            status += "  " + two(clock.sec) + "s";
        }

        text(
            dc,
            32,
            132,
            width - 64,
            16,
            status,
            Gfx.COLOR_LT_GRAY,
            true
        );

        // Fixed two-column, three-row lower grid for the approved layout.
        var gridTop = 151;
        var rowHeight = 21;
        var gridLeft = 18;
        var gridRight = width - 18;
        var gridWidth = gridRight - gridLeft;
        var columnWidth = (gridWidth / 2).toNumber();
        var gridCenter = gridLeft + columnWidth;

        for (var row = 0; row < 3; row += 1) {
            var y = gridTop + row * rowHeight;

            dataCell(
                dc,
                gridLeft + 3,
                y,
                columnWidth - 6,
                _slots[row * 2]
            );

            dataCell(
                dc,
                gridCenter + 3,
                y,
                columnWidth - 6,
                _slots[row * 2 + 1]
            );
        }

        if (_lines) {
            dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_BLACK);
            dc.drawLine(
                gridCenter,
                gridTop + 2,
                gridCenter,
                gridTop + rowHeight * 3 - 2
            );
            dc.drawLine(
                gridLeft + 8,
                gridTop + rowHeight,
                gridRight - 8,
                gridTop + rowHeight
            );
            dc.drawLine(
                gridLeft + 8,
                gridTop + rowHeight * 2,
                gridRight - 8,
                gridTop + rowHeight * 2
            );
        }

        drawBottomStatus(dc, width, height);

        if (_animating) {
            if (_animationFrame < 2) {
                _animationFrame += 1;
                Ui.requestUpdate();
            } else {
                _animationFrame = 0;
                _animating = false;
            }
        }
    }
}
