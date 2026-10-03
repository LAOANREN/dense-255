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
// No activation code or authorization watermark.
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
    var _slots = [1, 3, 2, 5, 4, 6, 7, 8];
    var _hours24 = true;
    var _seconds = true;
    var _lines = true;

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

        var defaults = [1, 3, 2, 5, 4, 6, 7, 8];

        for (var i = 0; i < 8; i += 1) {
            var selected = property(
                "slot" + (i + 1).toString(),
                defaults[i]
            );

            if (selected < 0 || selected > 13) {
                selected = defaults[i];
            }

            _slots[i] = selected;
        }

        _stamp = -1;
    }

    function onEnterSleep() {
        _awake = false;
    }

    function onExitSleep() {
        _awake = true;
        _stamp = -1;
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
        _phone = Sys.getDeviceSettings().phoneConnected;

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

        // Read the device weather cache at most once every ten minutes.
        if (_weatherStamp == -1 ||
            minute < _weatherStamp ||
            minute - _weatherStamp >= 10) {
            _weather = Weather.getCurrentConditions();
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

    function metricCell(dc, x, y, width, value) {
        if (value.length() == 0) {
            return;
        }

        var split = value.find(" ");

        if (split == null) {
            text(
                dc,
                x,
                y,
                width,
                20,
                value,
                Gfx.COLOR_WHITE,
                false
            );
            return;
        }

        var label = value.substring(0, split);
        var number = value.substring(split + 1, value.length());
        var font = Gfx.FONT_XTINY;
        var numberWidth = dc.getTextWidthInPixels(number, font);

        // Keep values intact; shorten the label first.
        if (numberWidth > width) {
            number = "--";
            numberWidth = dc.getTextWidthInPixels(number, font);
        }

        var labelWidth = width - numberWidth - 4;

        if (labelWidth > 0) {
            text(
                dc,
                x,
                y,
                labelWidth,
                20,
                label,
                Gfx.COLOR_LT_GRAY,
                false
            );
        }

        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);

        dc.drawText(
            x + width,
            y + ((20 - dc.getFontHeight(font)) / 2).toNumber(),
            font,
            number,
            Gfx.TEXT_JUSTIFY_RIGHT
        );
    }

    function metric(id) {
        if (id == 0) {
            return "";
        }

        if (id == 1) {
            return words("步数 ", "STP ") +
                integer(_info.steps);
        }

        if (id == 2) {
            var km = _info.distance == null
                ? null
                : _info.distance / 100000.0;

            return words("公里 ", "KM ") + decimal(km);
        }

        if (id == 3) {
            return words("热量 ", "KCAL ") +
                integer(_info.calories);
        }

        if (id == 4) {
            return words("心率 ", "HR ") +
                integer(_heart);
        }

        if (id == 5) {
            return words("楼层 ", "FLR ") +
                integer(_info.floorsClimbed);
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

            return words("强度分 ", "INT ") +
                integer(active);
        }

        if (id == 7) {
            var percent = null;

            if (_info.steps != null &&
                _info.stepGoal != null &&
                _info.stepGoal > 0) {
                percent = _info.steps * 100.0 /
                    _info.stepGoal;
            }

            return words("目标 ", "GOAL ") +
                integer(percent) + "%";
        }

        if (id == 8) {
            return words("电量 ", "BAT ") +
                integer(_battery) + "%";
        }

        if (id == 9) {
            var humidity = _weather == null
                ? null
                : _weather.relativeHumidity;

            return words("湿度 ", "HUM ") +
                integer(humidity) + "%";
        }

        if (id == 10) {
            var wind = _weather == null
                ? null
                : _weather.windSpeed;

            return words("风 ", "WND ") +
                decimal(wind) + "m/s";
        }

        if (id == 11) {
            var temperature = _weather == null
                ? null
                : _weather.temperature;

            return words("气温 ", "TEMP ") +
                integer(temperature) + "C";
        }

        if (id == 12) {
            var pressure = null;

            if (_weather != null &&
                _weather.pressure != null) {
                pressure = _weather.pressure / 100.0;
            }

            return words("气压 ", "hPa ") +
                integer(pressure);
        }

        if (id == 13) {
            return words("爬升 ", "UP ") +
                integer(_info.metersClimbed) + "m";
        }

        return "--";
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
            dc.drawLine(18, 148, width - 18, 148);
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

        // Four rows, two columns, kept inside the circular display.
        for (var row = 0; row < 4; row += 1) {
            var y = 150 + row * 20;
            var dy = y + 20 - height / 2;
            var radius = width / 2 - 4;

            var half = Math.sqrt(
                radius * radius - dy * dy
            ).toNumber();

            var left = centerX - half + 3;
            var cellWidth = half - 10;

            metricCell(
                dc,
                left,
                y,
                cellWidth,
                metric(_slots[row * 2])
            );

            metricCell(
                dc,
                centerX + 7,
                y,
                cellWidth,
                metric(_slots[row * 2 + 1])
            );

            if (_lines) {
                dc.setColor(
                    Gfx.COLOR_DK_GRAY,
                    Gfx.COLOR_BLACK
                );

                dc.drawLine(
                    centerX,
                    y + 4,
                    centerX,
                    y + 16
                );
            }
        }

        text(
            dc,
            76,
            232,
            width - 152,
            19,
            words("电量 ", "BAT ") +
                integer(_battery) + "%",
            _accent,
            true
        );
    }
}
