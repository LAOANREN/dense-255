using Toybox.Application as App;
using Toybox.Graphics as Gfx;
using Toybox.System as Sys;
using Toybox.Time as Time;
using Toybox.Time.Gregorian as Gregorian;
using Toybox.WatchUi as Ui;
using Toybox.Weather as Weather;
using Toybox.Math as Math;

// Forerunner 255 标准版：260 x 260 圆形 MIP。
// 照片版：天气、大时间、日期、人物背景、电池图标和百分比。
// 配套资源：resources/drawables/kipchoge.xml 和 kipchoge.jpg。
// 保留 KnightFace 类名及 loadSettings()，兼容原来的 App 入口。
class KnightFace extends Ui.WatchFace {
    var _photo = null;
    var _awake = false;
    var _wakeStart = -1;
    var _stamp = -1;
    var _weatherStamp = -1;

    var _weather = null;
    var _battery = null;
    var _phone = false;

    var _cn = true;
    var _accent = 0x00FFFF;
    var _hours24 = true;
    var _seconds = true;
    var _lines = true;

    // 原图在资源编译时缩放到 260 x 260。
    // 针对用户提供的方形照片，下移后让眼睛、笑容处于日期下方。
    // 此偏移会裁掉照片下部；这是为圆屏主动保留脸部的构图。
    var _photoOffsetY = 76;

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
        _stamp = -1;
        _weatherStamp = -1;
    }

    function loadPhoto() {
        // 资源只在进入视图时加载，不在每次刷新时解码。
        if (_photo == null) {
            _photo = Ui.loadResource(Rez.Drawables.KipchogeBackground);
        }
    }

    function onLayout(dc) {
        loadPhoto();
    }

    function onShow() {
        loadPhoto();
        _stamp = -1;
        _weatherStamp = -1;
    }

    function onHide() {
        _photo = null;
        _awake = false;
        _wakeStart = -1;
    }

    function onEnterSleep() {
        _awake = false;
        _wakeStart = -1;
        // 只请求一次完整重绘，清除秒数和抬腕高亮。
        Ui.requestUpdate();
    }

    function onExitSleep() {
        _awake = true;
        _wakeStart = Time.now().value();
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

    function refreshData(now) {
        // 每次完整刷新先检查连接，不能被分钟缓存提前挡住。
        var connected = Sys.getDeviceSettings().phoneConnected == true;
        if (connected != _phone) {
            _phone = connected;
            _weather = null;
            _weatherStamp = -1;
        }

        var minute = (now / 60).toNumber();
        if (_stamp != minute) {
            _stamp = minute;
            _battery = Sys.getSystemStats().battery;
        }

        // 断连时清空天气，禁止把此前缓存继续显示为当前天气。
        if (!_phone) {
            _weather = null;
            return;
        }

        var weatherReady = _weather != null &&
            (_weather.temperature != null ||
             _weather.windSpeed != null ||
             _weather.relativeHumidity != null);
        var interval = weatherReady ? 600 : 60;

        if (_weatherStamp == -1 ||
            now < _weatherStamp ||
            now - _weatherStamp >= interval) {
            // 只读取 Garmin 缓存；这里不会主动发起网络请求。
            // 返回 null 时也替换旧值，避免无限保留旧天气。
            _weather = Weather.getCurrentConditions();
            _weatherStamp = now;
        }
    }

    // 使用文字整个矩形最靠近圆边的一侧计算宽度，额外留出安全边距。
    function safeRowWidth(dc, top, height) {
        var width = dc.getWidth();
        var screenHeight = dc.getHeight();
        var diameter = width < screenHeight ? width : screenHeight;
        var radius = diameter / 2.0 - 6.0;
        var centerY = screenHeight / 2.0;
        var d1 = top - centerY;
        var d2 = top + height - centerY;
        if (d1 < 0) {
            d1 = -d1;
        }
        if (d2 < 0) {
            d2 = -d2;
        }
        var distance = d1 > d2 ? d1 : d2;
        if (distance >= radius) {
            return 0;
        }
        return (2.0 * Math.sqrt(radius * radius - distance * distance) - 8.0).toNumber();
    }

    function smallRowHeight(dc) {
        return dc.getFontHeight(Gfx.FONT_XTINY) + 4;
    }

    // 从完整的候选文案中选择能放下的一条；不截断数字或单位。
    function drawSmallRow(dc, top, height, candidates, color, badge) {
        var font = Gfx.FONT_XTINY;
        var available = safeRowWidth(dc, top, height) - 12;
        var shown = "--";
        for (var i = 0; i < candidates.size(); i += 1) {
            if (dc.getTextWidthInPixels(candidates[i], font) <= available) {
                shown = candidates[i];
                break;
            }
        }
        if (dc.getTextWidthInPixels(shown, font) > available) {
            return;
        }

        var centerX = (dc.getWidth() / 2).toNumber();
        var textWidth = dc.getTextWidthInPixels(shown, font);
        var textY = top + ((height - dc.getFontHeight(font)) / 2).toNumber();

        if (badge) {
            dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_BLACK);
            dc.fillRoundedRectangle(
                centerX - ((textWidth + 12) / 2).toNumber(),
                top,
                textWidth + 12,
                height,
                4
            );
        }
        dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_TRANSPARENT);
        dc.drawText(centerX + 1, textY + 1, font, shown, Gfx.TEXT_JUSTIFY_CENTER);
        dc.setColor(color, Gfx.COLOR_TRANSPARENT);
        dc.drawText(centerX, textY, font, shown, Gfx.TEXT_JUSTIFY_CENTER);
    }

    function drawWeather(dc, top, rowHeight) {
        var temperature = "--";
        var range = "--";
        var wind = "--";
        var humidity = "--";

        if (_phone && _weather != null) {
            if (_weather.temperature != null) {
                temperature = integer(_weather.temperature) + "C";
            }
            if (_weather.lowTemperature != null || _weather.highTemperature != null) {
                range = integer(_weather.lowTemperature) + "/" +
                    integer(_weather.highTemperature) + "C";
            }
            if (_weather.windSpeed != null) {
                wind = decimal(_weather.windSpeed) + "m/s";
            }
            if (_weather.relativeHumidity != null) {
                humidity = integer(_weather.relativeHumidity) + "%";
            }
        }

        drawSmallRow(
            dc, top, rowHeight,
            [
                words("气温 ", "TEMP ") + temperature + "  " + range,
                temperature + "  " + range,
                words("气温 ", "TEMP ") + temperature,
                temperature
            ],
            Gfx.COLOR_WHITE, true
        );
        drawSmallRow(
            dc, top + rowHeight + 2, rowHeight,
            [
                words("风 ", "W ") + wind + "  " + words("湿 ", "RH ") + humidity,
                wind + "  " + humidity,
                words("风 ", "W ") + wind,
                "--"
            ],
            Gfx.COLOR_WHITE, true
        );
    }

    function drawClock(dc, clock, top, height) {
        var hour = clock.hour;
        if (!_hours24) {
            hour = hour % 12;
            if (hour == 0) {
                hour = 12;
            }
        }
        var value = two(hour) + ":" + two(clock.min);
        var fonts = [
            Gfx.FONT_NUMBER_HOT,
            Gfx.FONT_NUMBER_MEDIUM,
            Gfx.FONT_NUMBER_MILD,
            Gfx.FONT_LARGE,
            Gfx.FONT_XTINY
        ];
        var font = Gfx.FONT_XTINY;
        var available = safeRowWidth(dc, top, height) - 18;
        for (var i = 0; i < fonts.size(); i += 1) {
            if (dc.getFontHeight(fonts[i]) <= height - 4 &&
                dc.getTextWidthInPixels(value, fonts[i]) <= available) {
                font = fonts[i];
                break;
            }
        }

        var centerX = (dc.getWidth() / 2).toNumber();
        var fontHeight = dc.getFontHeight(font);
        var textWidth = dc.getTextWidthInPixels(value, font);
        var textY = top + ((height - fontHeight) / 2).toNumber();

        dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_BLACK);
        dc.fillRoundedRectangle(
            centerX - ((textWidth + 18) / 2).toNumber(),
            textY - 2,
            textWidth + 18,
            fontHeight + 4,
            5
        );
        dc.setColor(_accent, Gfx.COLOR_TRANSPARENT);
        dc.drawText(centerX, textY, font, value, Gfx.TEXT_JUSTIFY_CENTER);

        if (_lines) {
            dc.setColor(_accent, Gfx.COLOR_TRANSPARENT);
            dc.drawLine(centerX - 38, top + height + 1,
                centerX + 38, top + height + 1);
        }
    }

    function drawDate(dc, date, clock, top, height) {
        var week = _cn
            ? ["日", "一", "二", "三", "四", "五", "六"]
            : ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];
        var base = two(date.month) + "/" + two(date.day) + " " +
            words("周", "") + week[date.day_of_week - 1];
        var standard = base;
        if (!_hours24) {
            standard += clock.hour < 12 ? " AM" : " PM";
        }
        var detailed = standard;
        if (_seconds && _awake) {
            detailed += "  " + two(clock.sec) + "s";
        }
        drawSmallRow(dc, top, height,
            [detailed, standard, base], Gfx.COLOR_WHITE, true);
    }

    function drawBatteryStatus(dc, now) {
        var level = 0;
        if (_battery != null) {
            level = Math.round(_battery).toNumber();
            if (level < 0) {
                level = 0;
            }
            if (level > 100) {
                level = 100;
            }
        }
        var label = _battery == null ? "--" : level.toString() + "%";
        var font = Gfx.FONT_XTINY;
        var fontHeight = dc.getFontHeight(font);
        var textWidth = dc.getTextWidthInPixels(label, font);
        var rowHeight = fontHeight + 6;
        var top = dc.getHeight() - 18 - rowHeight;
        var totalWidth = 25 + 7 + textWidth;

        // 100% 比 9% 宽，必要时仅把底部电量略微抬高。
        while (safeRowWidth(dc, top, rowHeight) < totalWidth + 10 &&
               top > dc.getHeight() - 64) {
            top -= 1;
        }
        var centerX = (dc.getWidth() / 2).toNumber();
        var x = centerX - (totalWidth / 2).toNumber();
        var iconY = top + ((rowHeight - 12) / 2).toNumber();
        var color = _battery != null && level <= 15 ? Gfx.COLOR_RED : _accent;

        dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_BLACK);
        dc.fillRoundedRectangle(x - 5, top, totalWidth + 10, rowHeight, 5);

        // 抬腕后利用系统每秒更新播放三帧外框高亮。
        // 不在 onUpdate 内递归 requestUpdate，不模拟电量增长。
        var elapsed = _wakeStart < 0 ? -1 : now - _wakeStart;
        if (_awake && elapsed >= 0 && elapsed < 3) {
            var padding = elapsed == 1 ? 3 : 2;
            dc.setColor(elapsed == 1 ? Gfx.COLOR_WHITE : color,
                Gfx.COLOR_TRANSPARENT);
            dc.drawRectangle(x - padding, iconY - padding,
                22 + padding * 2, 12 + padding * 2);
        }

        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawRectangle(x, iconY, 22, 12);
        dc.fillRectangle(x + 22, iconY + 4, 3, 4);
        if (_battery != null) {
            var fill = (18 * level / 100.0).toNumber();
            if (fill > 0) {
                dc.setColor(color, Gfx.COLOR_TRANSPARENT);
                dc.fillRectangle(x + 2, iconY + 2, fill, 8);
            }
        }
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(x + 32, top + 3, font, label, Gfx.TEXT_JUSTIFY_LEFT);
    }

    function onUpdate(dc) {
        var moment = Time.now();
        var now = moment.value();
        refreshData(now);

        dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_BLACK);
        dc.clear();
        if (_photo != null) {
            dc.drawBitmap((dc.getWidth() - 260) / 2,
                _photoOffsetY + (dc.getHeight() - 260) / 2, _photo);
        }

        var clock = Sys.getClockTime();
        var date = Gregorian.info(moment, Time.FORMAT_SHORT);
        var rowHeight = smallRowHeight(dc);
        var weatherTop = 32;
        var clockTop = weatherTop + rowHeight * 2 + 4;
        var dateTop = 136;
        var clockHeight = dateTop - clockTop - 4;

        drawWeather(dc, weatherTop, rowHeight);
        drawClock(dc, clock, clockTop, clockHeight);
        drawDate(dc, date, clock, dateTop, rowHeight);
        drawBatteryStatus(dc, now);
    }
}
