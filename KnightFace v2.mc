using Toybox.Application as App;
using Toybox.Graphics as Gfx;
using Toybox.System as Sys;
using Toybox.Time as Time;
using Toybox.Time.Gregorian as Gregorian;
using Toybox.WatchUi as Ui;
using Toybox.Activity as Activity;
using Toybox.ActivityMonitor as AM;
using Toybox.Sensor as Sensor;
using Toybox.Weather as Weather;
using Toybox.Math as Math;

// KnightFace v2 rebuilt for the Garmin Forerunner 255.
//
// The display is 260 x 260 on the Forerunner 255.  The layout follows the
// supplied round-face reference: weather at the top, date and large time in
// the middle, a compass pointer beside the time, the original two-column /
// three-row data grid below it, and the Kipchoge pixel portrait in the
// remaining lower area.
//
// A watch face cannot start a continuous GPS acquisition on Connect IQ.
// The heading code therefore uses the latest heading exposed by the current
// activity and falls back to the watch compass sensor.  A device app or a
// widget is required if a permanently live GPS heading is mandatory.
class KnightFace extends Ui.WatchFace {
    var _awake = true;
    var _dataMinute = -1;
    var _weatherMinute = -1;

    var _info = null;
    var _weather = null;
    var _sensor = null;
    var _heart = null;
    var _battery = null;
    var _altitude = null;
    var _pressure = null;
    var _heading = null;
    var _phone = false;

    var _cn = true;
    var _accent = 0x00FFFF;
    var _hours24 = true;
    var _seconds = true;
    var _lines = true;

    // The six cells used by the approved lower layout.
    var _slots = [1, 13, 2, 3, 4, 12];

    // 0 = normal smile, 1 = blink, 2 = small nod.
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
        _dataMinute = -1;
        _weatherMinute = -1;
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
        _dataMinute = -1;
        _weatherMinute = -1;
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

    function integerUnit(value, unit) {
        if (value == null) {
            return "--";
        }

        return integer(value) + unit;
    }

    function decimalUnit(value, unit) {
        if (value == null) {
            return "--";
        }

        return decimal(value) + unit;
    }

    function two(value) {
        return value.format("%02d");
    }

    function minuteStamp() {
        return (Time.now().value() / 60).toNumber();
    }

    // Read activity, battery, heart rate, weather, altitude and pressure.
    // ActivityMonitor calories and distance are day totals and are deliberately
    // read again once per minute, so the values reset correctly at midnight.
    function refreshData() {
        var minute = minuteStamp();

        if (_dataMinute == minute) {
            return;
        }

        _dataMinute = minute;
        _info = AM.getInfo();
        _battery = Sys.getSystemStats().battery;

        var settings = Sys.getDeviceSettings();
        var connected = settings != null && settings.phoneConnected;
        var wasPhoneConnected = _phone;
        _phone = connected;

        if (_phone != wasPhoneConnected) {
            _weatherMinute = -1;
        }

        // Weather is a Garmin Connect phone cache.  Do not keep displaying
        // stale weather after the phone connection has gone away.
        if (!_phone) {
            _weather = null;
        }

        _sensor = Sensor.getInfo();

        _pressure = null;
        if (_sensor != null && _sensor.pressure != null) {
            // Sensor pressure is reported in Pa; the face displays hPa.
            _pressure = _sensor.pressure / 100.0;
        }

        // The lower grid calls this value 海拔.  It is current elevation,
        // rather than ActivityMonitor.metersClimbed, which is a daily stair
        // climbing total.  The requested offline behavior is --.
        _altitude = null;
        if (_phone) {
            var activityInfo = Activity.getActivityInfo();

            if (activityInfo != null && activityInfo.altitude != null) {
                _altitude = activityInfo.altitude;
            } else if (_sensor != null && _sensor.altitude != null) {
                _altitude = _sensor.altitude;
            }
        }

        _heart = null;

        // Prefer a current sensor value, then use the recent history cache.
        if (_sensor != null &&
            _sensor.heartRate != null &&
            _sensor.heartRate > 0 &&
            _sensor.heartRate < 255) {
            _heart = _sensor.heartRate;
        }

        if (_heart == null) {
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
        }

        if (_phone) {
            var weatherReady = _weather != null &&
                (_weather.temperature != null ||
                 _weather.windSpeed != null ||
                 _weather.relativeHumidity != null);
            var weatherInterval = weatherReady ? 10 : 1;

            if (_weatherMinute == -1 ||
                minute < _weatherMinute ||
                minute - _weatherMinute >= weatherInterval) {
                var cachedWeather = Weather.getCurrentConditions();

                if (cachedWeather != null) {
                    _weather = cachedWeather;
                }

                _weatherMinute = minute;
            }
        }
    }

    // A watch face cannot request a live GPS stream.  Activity.Info.currentHeading
    // is the latest true-north heading supplied by the activity system.  The
    // sensor heading provides a compass fallback when the watch supports it.
    function refreshHeading() {
        var heading = null;
        var activityInfo = Activity.getActivityInfo();

        if (activityInfo != null && activityInfo.currentHeading != null) {
            heading = activityInfo.currentHeading;
        }

        if (heading == null) {
            var sensorInfo = Sensor.getInfo();

            if (sensorInfo != null && sensorInfo.heading != null) {
                heading = sensorInfo.heading;
            }
        }

        // Keep the last good value during a short sensor gap.  A fresh install
        // with no heading data still shows -- and no misleading pointer.
        if (heading != null) {
            _heading = heading;
        }
    }

    function fitForDc(dc, value, width, font) {
        var shown = value == null ? "--" : value;

        while (shown.length() > 0 &&
               dc.getTextWidthInPixels(shown, font) > width) {
            shown = shown.substring(0, shown.length() - 1);
        }

        return shown;
    }

    function text(dc, x, y, width, height, value, color, centered) {
        var font = Gfx.FONT_XTINY;
        var shown = fitForDc(dc, value, width, font);

        dc.setColor(color, Gfx.COLOR_BLACK);

        var textY = y +
            ((height - dc.getFontHeight(font)) / 2).toNumber();
        var textX = centered
            ? x + (width / 2).toNumber()
            : x;
        var alignment = centered
            ? Gfx.TEXT_JUSTIFY_CENTER
            : Gfx.TEXT_JUSTIFY_LEFT;

        dc.drawText(textX, textY, font, shown, alignment);
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
        if (id == 1) {
            return _info == null ? "--" : integer(_info.steps);
        }

        if (id == 2) {
            if (_info == null || _info.distance == null) {
                return "--";
            }

            // ActivityMonitor distance is in centimeters.
            return decimalUnit(_info.distance / 100000.0, "km");
        }

        if (id == 3) {
            return _info == null
                ? "--"
                : integerUnit(_info.calories, "kcal");
        }

        if (id == 4) {
            return integerUnit(_heart, "bpm");
        }

        if (id == 5) {
            return _info == null ? "--" : integer(_info.floorsClimbed);
        }

        if (id == 6) {
            var active = null;

            if (_info != null && _info.activeMinutesDay != null) {
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

            if (_info != null &&
                _info.steps != null &&
                _info.stepGoal != null &&
                _info.stepGoal > 0) {
                percent = _info.steps * 100.0 /
                    _info.stepGoal;
            }

            return integerUnit(percent, "%");
        }

        if (id == 8) {
            return integerUnit(_battery, "%");
        }

        if (id == 9) {
            var humidity = _weather == null
                ? null
                : _weather.relativeHumidity;
            return integerUnit(humidity, "%");
        }

        if (id == 10) {
            var wind = _weather == null
                ? null
                : _weather.windSpeed;
            return decimalUnit(wind, "m/s");
        }

        if (id == 11) {
            var temperature = _weather == null
                ? null
                : _weather.temperature;
            return integerUnit(temperature, "C");
        }

        if (id == 12) {
            return integerUnit(_pressure, "hPa");
        }

        if (id == 13) {
            return integerUnit(_altitude, "m");
        }

        return "--";
    }

    function dataCell(dc, x, y, width, id) {
        var label = metricLabel(id);
        var value = metricValue(id);
        var font = Gfx.FONT_XTINY;
        var rowHeight = 18;
        var gap = 2;
        var shownValue = fitForDc(dc, value, width - 4, font);
        var valueWidth = dc.getTextWidthInPixels(shownValue, font);
        var labelWidth = width - valueWidth - gap - 4;
        var shownLabel = fitForDc(dc, label, labelWidth, font);

        if (labelWidth < 0) {
            labelWidth = 0;
            shownLabel = "";
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
            shownValue,
            Gfx.TEXT_JUSTIFY_RIGHT
        );
    }

    function directionIndex() {
        if (_heading == null) {
            return -1;
        }

        // Connect IQ headings are radians clockwise from true north.
        var degrees = _heading * 57.2957795;

        while (degrees < 0) {
            degrees += 360.0;
        }

        while (degrees >= 360.0) {
            degrees -= 360.0;
        }

        var index = Math.round((degrees + 22.5) / 45.0).toNumber();

        if (index >= 8) {
            index = 0;
        }

        return index;
    }

    function directionName(index) {
        if (index < 0) {
            return "--";
        }

        var names = _cn
            ? ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
            : ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];

        return names[index];
    }

    function drawCompassPointer(dc, cx, cy, index) {
        if (index < 0) {
            return;
        }

        var dxs = [0, 1, 1, 1, 0, -1, -1, -1];
        var dys = [-1, -1, 0, 1, 1, 1, 0, -1];
        var dx = dxs[index];
        var dy = dys[index];
        var px = -dy;
        var py = dx;

        var tipX = cx + dx * 11;
        var tipY = cy + dy * 11;
        var tailX = cx - dx * 8;
        var tailY = cy - dy * 8;
        var leftX = tipX - dx * 4 + px * 3;
        var leftY = tipY - dy * 4 + py * 3;
        var rightX = tipX - dx * 4 - px * 3;
        var rightY = tipY - dy * 4 - py * 3;

        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.drawLine(tailX, tailY, tipX, tipY);

        dc.setColor(_accent, Gfx.COLOR_BLACK);
        dc.drawLine(tipX, tipY, leftX, leftY);
        dc.drawLine(tipX, tipY, rightX, rightY);
        dc.fillCircle(tipX, tipY, 1);
        dc.fillCircle(cx, cy, 2);
    }

    function drawSun(dc, cx, cy) {
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.drawCircle(cx, cy, 5);
        dc.drawLine(cx, cy - 10, cx, cy - 7);
        dc.drawLine(cx, cy + 7, cx, cy + 10);
        dc.drawLine(cx - 10, cy, cx - 7, cy);
        dc.drawLine(cx + 7, cy, cx + 10, cy);
        dc.drawLine(cx - 7, cy - 7, cx - 5, cy - 5);
        dc.drawLine(cx + 5, cy + 5, cx + 7, cy + 7);
        dc.drawLine(cx + 5, cy - 5, cx + 7, cy - 7);
        dc.drawLine(cx - 7, cy + 7, cx - 5, cy + 5);
    }

    function drawRing(dc, width, height, cx) {
        var radius = width < height ? width / 2 - 3 : height / 2 - 3;
        dc.setColor(_accent, Gfx.COLOR_BLACK);
        dc.drawCircle(cx, (height / 2).toNumber(), radius);

        // Four unobtrusive reference ticks echo the supplied round design.
        var cy = (height / 2).toNumber();
        dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_BLACK);
        dc.drawLine(cx, 4, cx, 9);
        dc.drawLine(cx, height - 9, cx, height - 4);
        dc.drawLine(4, cy, 9, cy);
        dc.drawLine(width - 9, cy, width - 4, cy);
    }

    function drawClock(dc, centerX, top, hour, minute, width) {
        var font = Gfx.FONT_NUMBER_HOT;
        var hourText = two(hour);
        var minuteText = two(minute);
        var colonText = ":";
        var totalText = hourText + colonText + minuteText;

        if (dc.getTextWidthInPixels(totalText, font) > width ||
            dc.getFontHeight(font) > 43) {
            font = Gfx.FONT_NUMBER_MEDIUM;
        }

        var hourWidth = dc.getTextWidthInPixels(hourText, font);
        var colonWidth = dc.getTextWidthInPixels(colonText, font);
        var minuteWidth = dc.getTextWidthInPixels(minuteText, font);
        var totalWidth = hourWidth + colonWidth + minuteWidth;
        var startX = centerX - (totalWidth / 2).toNumber();
        var textY = top +
            ((45 - dc.getFontHeight(font)) / 2).toNumber();

        dc.setColor(_accent, Gfx.COLOR_BLACK);
        dc.drawText(
            startX + (hourWidth / 2).toNumber(),
            textY,
            font,
            hourText,
            Gfx.TEXT_JUSTIFY_CENTER
        );

        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.drawText(
            startX + hourWidth + (colonWidth / 2).toNumber(),
            textY,
            font,
            colonText,
            Gfx.TEXT_JUSTIFY_CENTER
        );
        dc.drawText(
            startX + hourWidth + colonWidth +
                (minuteWidth / 2).toNumber(),
            textY,
            font,
            minuteText,
            Gfx.TEXT_JUSTIFY_CENTER
        );
    }

    function pixelRow(dc, cx, y, left, right, color) {
        dc.setColor(color, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx - left, y, left + right + 1, 2);
    }

    // Code-drawn pixel portrait.  It uses the supplied portrait's dark red,
    // terracotta, orange, green and white palette instead of a generic circle.
    // Keeping it as code avoids a bitmap resource and leaves room for the
    // battery percentage on the forehead.
    function drawKipchogeAvatar(dc, cx, top, frame) {
        var shift = frame == 2 ? 1 : 0;
        var outline = 0xF0F0F0;
        var black = 0x171318;
        var skinShadow = 0x6B3032;
        var skinDark = 0x8D4035;
        var skin = 0xB85A3D;
        var skinMid = 0xC96A43;
        var skinLight = 0xDA804C;
        var green = 0x6AD17A;
        var shirt = 0x2B2837;
        var shirtShadow = 0x181622;
        var vest = 0x4D2630;

        // Shoulders and shirt are behind the head and neck.
        dc.setColor(outline, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx - 27, top + 34, 54, 8);
        dc.setColor(shirtShadow, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx - 25, top + 34, 50, 8);
        dc.setColor(shirt, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx - 21, top + 33, 42, 9);
        dc.setColor(vest, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx - 18, top + 33, 7, 9);
        dc.fillRectangle(cx + 11, top + 33, 7, 9);

        // Neck, with a white shirt edge at the bottom.
        dc.setColor(outline, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx - 10, top + 26 + shift, 20, 16 - shift);
        dc.setColor(skinShadow, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx - 8, top + 27 + shift, 16, 13 - shift);
        dc.setColor(skin, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx - 5, top + 27 + shift, 10, 13 - shift);
        dc.setColor(0xE8E0D0, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx - 8, top + 40, 16, 2);

        // White pixel outline around the head.
        pixelRow(dc, cx, top + shift, 8, 8, outline);
        pixelRow(dc, cx, top + 2 + shift, 14, 14, outline);
        pixelRow(dc, cx, top + 4 + shift, 18, 18, outline);
        pixelRow(dc, cx, top + 6 + shift, 20, 20, outline);
        pixelRow(dc, cx, top + 8 + shift, 21, 21, outline);
        pixelRow(dc, cx, top + 10 + shift, 22, 22, outline);
        pixelRow(dc, cx, top + 12 + shift, 22, 22, outline);
        pixelRow(dc, cx, top + 14 + shift, 23, 23, outline);
        pixelRow(dc, cx, top + 16 + shift, 23, 23, outline);
        pixelRow(dc, cx, top + 18 + shift, 23, 23, outline);
        pixelRow(dc, cx, top + 20 + shift, 22, 22, outline);
        pixelRow(dc, cx, top + 22 + shift, 21, 21, outline);
        pixelRow(dc, cx, top + 24 + shift, 19, 19, outline);
        pixelRow(dc, cx, top + 26 + shift, 16, 16, outline);
        pixelRow(dc, cx, top + 28 + shift, 12, 12, outline);

        // Face fill, keeping the pixel-step silhouette.
        pixelRow(dc, cx, top + 2 + shift, 7, 7, skinDark);
        pixelRow(dc, cx, top + 4 + shift, 12, 12, skin);
        pixelRow(dc, cx, top + 6 + shift, 16, 16, skin);
        pixelRow(dc, cx, top + 8 + shift, 18, 18, skinMid);
        pixelRow(dc, cx, top + 10 + shift, 19, 19, skinMid);
        pixelRow(dc, cx, top + 12 + shift, 20, 20, skin);
        pixelRow(dc, cx, top + 14 + shift, 21, 21, skin);
        pixelRow(dc, cx, top + 16 + shift, 21, 21, skinMid);
        pixelRow(dc, cx, top + 18 + shift, 21, 21, skinMid);
        pixelRow(dc, cx, top + 20 + shift, 20, 20, skin);
        pixelRow(dc, cx, top + 22 + shift, 19, 19, skin);
        pixelRow(dc, cx, top + 24 + shift, 17, 17, skinDark);
        pixelRow(dc, cx, top + 26 + shift, 14, 14, skinShadow);
        pixelRow(dc, cx, top + 28 + shift, 10, 10, skinShadow);

        // Ears and the green edge visible in the supplied artwork.
        dc.setColor(outline, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx - 25, top + 13 + shift, 5, 10);
        dc.fillRectangle(cx + 20, top + 13 + shift, 5, 10);
        dc.setColor(skinDark, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx - 23, top + 14 + shift, 4, 8);
        dc.fillRectangle(cx + 19, top + 14 + shift, 4, 8);
        dc.setColor(green, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx - 21, top + 7 + shift, 2, 8);
        dc.fillRectangle(cx + 19, top + 7 + shift, 2, 8);
        dc.fillRectangle(cx - 20, top + 23 + shift, 2, 5);
        dc.fillRectangle(cx + 18, top + 23 + shift, 2, 5);

        // Head shading and the close-cropped hair line.
        dc.setColor(skinShadow, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx - 17, top + 7 + shift, 6, 18);
        dc.fillRectangle(cx - 12, top + 23 + shift, 5, 6);
        dc.setColor(skinLight, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx + 10, top + 9 + shift, 8, 13);
        dc.fillRectangle(cx + 7, top + 21 + shift, 9, 5);
        dc.setColor(black, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx - 11, top + 3 + shift, 22, 3);
        dc.fillRectangle(cx - 16, top + 6 + shift, 7, 2);
        dc.fillRectangle(cx + 9, top + 6 + shift, 7, 2);

        // Brows.
        dc.fillRectangle(cx - 15, top + 11 + shift, 10, 2);
        dc.fillRectangle(cx + 5, top + 11 + shift, 10, 2);

        var eyeY = top + 14 + shift;

        if (frame == 1) {
            // Single blink frame: both eyelids close briefly.
            dc.setColor(black, Gfx.COLOR_BLACK);
            dc.fillRectangle(cx - 14, eyeY + 2, 10, 2);
            dc.fillRectangle(cx + 4, eyeY + 2, 10, 2);
            dc.setColor(skinLight, Gfx.COLOR_BLACK);
            dc.fillRectangle(cx - 11, eyeY + 4, 5, 2);
            dc.fillRectangle(cx + 7, eyeY + 4, 5, 2);
        } else {
            // Open eyes with the black/brown outline and small white highlights.
            dc.setColor(black, Gfx.COLOR_BLACK);
            dc.fillRectangle(cx - 14, eyeY + 1, 11, 5);
            dc.fillRectangle(cx + 3, eyeY + 1, 11, 5);
            dc.setColor(0xF0D5B0, Gfx.COLOR_BLACK);
            dc.fillRectangle(cx - 11, eyeY + 2, 6, 3);
            dc.fillRectangle(cx + 6, eyeY + 2, 6, 3);
            dc.setColor(black, Gfx.COLOR_BLACK);
            dc.fillRectangle(cx - 8, eyeY + 1, 3, 4);
            dc.fillRectangle(cx + 8, eyeY + 1, 3, 4);
            dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
            dc.fillRectangle(cx - 7, eyeY + 1, 1, 1);
            dc.fillRectangle(cx + 9, eyeY + 1, 1, 1);
        }

        // Nose and a calm, slightly smiling mouth.
        dc.setColor(skinLight, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx + 1, top + 18 + shift, 6, 6);
        dc.setColor(skinShadow, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx - 2, top + 22 + shift, 9, 2);
        dc.setColor(black, Gfx.COLOR_BLACK);
        dc.drawLine(cx - 10, top + 26 + shift, cx - 3, top + 27 + shift);
        dc.drawLine(cx - 3, top + 27 + shift, cx + 8, top + 26 + shift);
        dc.setColor(skinLight, Gfx.COLOR_BLACK);
        dc.fillRectangle(cx - 5, top + 28 + shift, 10, 2);

        // Battery percentage on the forehead, as requested.
        var batteryText = _battery == null
            ? "--"
            : integer(_battery) + "%";
        text(
            dc,
            cx - 10,
            top + 6 + shift,
            20,
            9,
            batteryText,
            _accent,
            true
        );
    }

    function drawBottomPortrait(dc, width, height) {
        var centerX = (width / 2).toNumber();
        var top = height - 42;
        var frame = _animating ? _animationFrame : 0;

        // Small colored bars retain the lower decorative character of the
        // supplied reference without taking space from the portrait.
        dc.setColor(_accent, Gfx.COLOR_BLACK);
        dc.drawLine(27, top + 2, centerX - 31, top + 2);
        dc.setColor(0xFF1493, Gfx.COLOR_BLACK);
        dc.drawLine(centerX + 31, top + 2, width - 27, top + 2);

        drawKipchogeAvatar(dc, centerX, top, frame);
    }

    function drawLowerGrid(dc, width, height) {
        var gridTop = 163;
        var rowHeight = 18;
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
    }

    function onUpdate(dc) {
        refreshData();
        refreshHeading();

        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_BLACK);
        dc.clear();

        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = (width / 2).toNumber();

        drawRing(dc, width, height, centerX);

        var clock = Sys.getClockTime();
        var date = Gregorian.info(
            Time.now(),
            Time.FORMAT_SHORT
        );

        var week = _cn
            ? ["日", "一", "二", "三", "四", "五", "六"]
            : ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];
        var weekday = date.day_of_week;

        if (weekday < 1 || weekday > 7) {
            weekday = 1;
        }

        var temperature = _weather == null
            ? null
            : _weather.temperature;
        var high = _weather == null
            ? null
            : _weather.highTemperature;
        var low = _weather == null
            ? null
            : _weather.lowTemperature;
        var wind = _weather == null
            ? null
            : _weather.windSpeed;
        var humidity = _weather == null
            ? null
            : _weather.relativeHumidity;

        // Weather band.
        text(
            dc,
            25,
            18,
            66,
            18,
            integerUnit(temperature, "C"),
            Gfx.COLOR_WHITE,
            true
        );
        text(
            dc,
            25,
            37,
            66,
            16,
            integerUnit(low, "C") + "/" + integerUnit(high, "C"),
            Gfx.COLOR_LT_GRAY,
            true
        );
        text(
            dc,
            91,
            18,
            93,
            17,
            words("风 ", "WIND ") + decimalUnit(wind, "m/s"),
            Gfx.COLOR_WHITE,
            true
        );
        text(
            dc,
            91,
            37,
            93,
            17,
            words("湿度 ", "RH ") + integerUnit(humidity, "%"),
            Gfx.COLOR_WHITE,
            true
        );
        drawSun(dc, width - 43, 27);
        text(
            dc,
            width - 68,
            39,
            50,
            15,
            words("晴", "CLEAR"),
            Gfx.COLOR_WHITE,
            true
        );

        // Date line.
        text(
            dc,
            41,
            62,
            width - 82,
            19,
            two(date.month) + "/" + two(date.day) +
                " " + words("周", "") + week[weekday - 1],
            _accent,
            true
        );

        if (_lines) {
            dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_BLACK);
            dc.drawLine(35, 84, width - 35, 84);
        }

        var hour = clock.hour;

        if (!_hours24) {
            hour = hour % 12;

            if (hour == 0) {
                hour = 12;
            }
        }

        // Large two-color clock, matching the supplied cyan/white reference.
        drawClock(dc, centerX + 18, 88, hour, clock.min, width - 78);

        var sector = directionIndex();
        drawCompassPointer(dc, centerX - 71, 111, sector);
        text(
            dc,
            centerX - 91,
            123,
            40,
            16,
            directionName(sector),
            Gfx.COLOR_WHITE,
            true
        );

        // Seconds are shown only during the high-power wrist-raise period.
        if (_seconds && _awake) {
            text(
                dc,
                centerX + 78,
                111,
                25,
                18,
                two(clock.sec),
                Gfx.COLOR_WHITE,
                true
            );
        }

        var status = _phone
            ? words("已连接", "LINK")
            : words("未连接", "OFFLINE");
        text(
            dc,
            72,
            140,
            width - 144,
            16,
            status,
            Gfx.COLOR_LT_GRAY,
            true
        );

        drawLowerGrid(dc, width, height);
        drawBottomPortrait(dc, width, height);

        // The system calls onUpdate once per second while the watch face is
        // awake.  Requesting one more update keeps the three portrait frames
        // visible on devices that coalesce a frame.
        if (_animating && _awake) {
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
