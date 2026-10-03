using Toybox.Application as App;
using Toybox.WatchUi as Ui;

class KnightFaceApp extends App.AppBase {
    var _view;

    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() {
        _view = new KnightFace();
        return [ _view ];
    }

    function onSettingsChanged() {
        if (_view != null) { _view.loadSettings(); }
        Ui.requestUpdate();
    }
}
