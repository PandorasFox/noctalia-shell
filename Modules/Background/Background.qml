import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Services.Compositor
import qs.Services.UI

Variants {
  id: backgroundVariants
  model: Quickshell.screens

  delegate: Loader {

    required property ShellScreen modelData

    active: modelData && Settings.data.wallpaper.enabled

    sourceComponent: PanelWindow {
      id: root

      // Internal state management
      property string transitionType: "fade"
      property real transitionProgress: 0
      property bool isStartupTransition: true
      property bool wallpaperReady: false

      visible: wallpaperReady

      readonly property real edgeSmoothness: Settings.data.wallpaper.transitionEdgeSmoothness
      readonly property var allTransitions: WallpaperService.allTransitions
      readonly property bool transitioning: transitionAnimation.running

      // Wipe direction: 0=left, 1=right, 2=up, 3=down
      property real wipeDirection: 0

      // Disc
      property real discCenterX: 0.5
      property real discCenterY: 0.5

      // Stripe
      property real stripesCount: 16
      property real stripesAngle: 0

      // Pixelate
      property real pixelateMaxBlockSize: 64.0

      // Honeycomb
      property real honeycombCellSize: 0.04
      property real honeycombCenterX: 0.5
      property real honeycombCenterY: 0.5

      // Used to debounce wallpaper changes
      property string futureWallpaper: ""
      // Track the original wallpaper path being transitioned to (before caching)
      property string transitioningToOriginalPath: ""

      // Fillmode default is "crop"
      property real fillMode: WallpaperService.getFillModeUniform()
      property vector4d fillColor: Qt.vector4d(Settings.data.wallpaper.fillColor.r, Settings.data.wallpaper.fillColor.g, Settings.data.wallpaper.fillColor.b, 1.0)

      // Parallax scrolling state
      readonly property bool effectiveScrolling: fillMode > 4.5
      property real scrollX: 50    // 0-100, current animated position
      property real scrollY: 50    // 0-100, current animated position
      property bool _firstScrollUpdate: true

      // Solid color mode - track whether current/next are solid colors
      property bool isSolid1: false
      property bool isSolid2: false
      property color _solidColor1: Settings.data.wallpaper.solidColor
      property color _solidColor2: Settings.data.wallpaper.solidColor
      property vector4d solidColor1: Qt.vector4d(_solidColor1.r, _solidColor1.g, _solidColor1.b, 1.0)
      property vector4d solidColor2: Qt.vector4d(_solidColor2.r, _solidColor2.g, _solidColor2.b, 1.0)

      // Workspace monitoring for parallax scrolling
      Connections {
        target: CompositorService
        enabled: root.effectiveScrolling
        function onWorkspaceChanged() {
          root._updateScrollTarget();
        }
      }

      function _updateScrollTarget() {
        if (!effectiveScrolling) return;

        var workspaces = CompositorService.workspaces;
        if (!workspaces || workspaces.count === 0) return;

        // Collect workspaces on this monitor and find the active one.
        // Use isActive (visible on output) instead of isFocused (global keyboard focus)
        // so that cursor moving between monitors doesn't trigger scroll changes.
        var activeIdx = -1;
        var outputWorkspaces = [];

        for (var i = 0; i < workspaces.count; i++) {
          var ws = workspaces.get(i);
          if (ws.output === modelData.name) {
            if (ws.isActive) {
              activeIdx = outputWorkspaces.length;
            }
            outputWorkspaces.push(ws);
          }
        }

        if (activeIdx < 0 || outputWorkspaces.length <= 1) {
          // No change — keep current target to avoid spurious animation
          return;
        }

        var scrollPos = activeIdx / (outputWorkspaces.length - 1) * 100;

        // Niri is vertical, all others are horizontal
        var newTargetX = CompositorService.isNiri ? 50 : scrollPos;
        var newTargetY = CompositorService.isNiri ? scrollPos : 50;

        scrollAnim.startAnimation(newTargetX, newTargetY);
      }

      // Analytical damped harmonic oscillator spring (matches Niri's spring.rs / libadwaita)
      QtObject {
        id: scrollAnim

        property real damping: CompositorService.isNiri ? 63.25 : 89.44
        property real stiffness: CompositorService.isNiri ? 1000.0 : 2000.0
        property real mass: 1.0

        property real startX: 50
        property real startY: 50
        property real targetX: 50
        property real targetY: 50
        property real startTime: 0

        // Analytical spring position at time t (seconds) from 'from' towards 'to'.
        // Based on the damped harmonic oscillator closed-form solution.
        function springPosition(t, from, to) {
          if (t <= 0) return from;
          var beta = damping / (2 * mass);
          var omega0 = Math.sqrt(stiffness / mass);
          var x0 = from - to;
          var envelope = Math.exp(-beta * t);
          if (Math.abs(x0 * envelope) < 0.01) return to;

          if (Math.abs(beta - omega0) < 0.0001) {
            // Critically damped
            return to + envelope * (x0 + beta * x0 * t);
          } else if (beta < omega0) {
            // Underdamped
            var omega1 = Math.sqrt(omega0 * omega0 - beta * beta);
            return to + envelope * (x0 * Math.cos(omega1 * t) + (beta * x0 / omega1) * Math.sin(omega1 * t));
          } else {
            // Overdamped
            var omega2 = Math.sqrt(beta * beta - omega0 * omega0);
            var coshV = function(v) { return (Math.exp(v) + Math.exp(-v)) / 2; };
            var sinhV = function(v) { return (Math.exp(v) - Math.exp(-v)) / 2; };
            return to + envelope * (x0 * coshV(omega2 * t) + (beta * x0 / omega2) * sinhV(omega2 * t));
          }
        }

        function startAnimation(newTargetX, newTargetY) {
          var now = Date.now() / 1000.0;

          // Compute current position from in-flight animation
          var t = Math.max(0, scrollFrameAnim.currentTime - startTime);
          var currentX = springPosition(t, startX, targetX);
          var currentY = springPosition(t, startY, targetY);

          // Skip if already at target
          if (Math.abs(newTargetX - currentX) < 0.01 && Math.abs(newTargetY - currentY) < 0.01) {
            if (root._firstScrollUpdate) root._firstScrollUpdate = false;
            return;
          }

          // First update: snap directly, no animation
          if (root._firstScrollUpdate) {
            root._firstScrollUpdate = false;
            root.scrollX = newTargetX;
            root.scrollY = newTargetY;
            startX = newTargetX;
            startY = newTargetY;
            targetX = newTargetX;
            targetY = newTargetY;
            WallpaperService.setScrollPosition(modelData.name, root.scrollX, root.scrollY);
            return;
          }

          // Chain from current position
          startX = currentX;
          startY = currentY;
          targetX = newTargetX;
          targetY = newTargetY;
          startTime = scrollFrameAnim.running ? scrollFrameAnim.currentTime : now;
          if (!scrollFrameAnim.running) {
            scrollFrameAnim.currentTime = now;
            scrollFrameAnim.running = true;
          }
        }
      }

      // FrameAnimation for vsync-accurate frame deltas (not locked to 16ms Timer)
      FrameAnimation {
        id: scrollFrameAnim
        running: false

        property real currentTime: 0

        onRunningChanged: {
          if (running) {
            currentTime = Date.now() / 1000.0;
          } else {
            WallpaperService.setScrollPosition(modelData.name, root.scrollX, root.scrollY);
          }
        }

        onTriggered: {
          currentTime += frameTime;

          var t = currentTime - scrollAnim.startTime;
          root.scrollX = scrollAnim.springPosition(t, scrollAnim.startX, scrollAnim.targetX);
          root.scrollY = scrollAnim.springPosition(t, scrollAnim.startY, scrollAnim.targetY);

          var settledX = Math.abs(scrollAnim.targetX - root.scrollX) < 0.01;
          var settledY = Math.abs(scrollAnim.targetY - root.scrollY) < 0.01;

          if (settledX && settledY) {
            root.scrollX = scrollAnim.targetX;
            root.scrollY = scrollAnim.targetY;
            running = false;
          }

          WallpaperService.setScrollPosition(modelData.name, root.scrollX, root.scrollY);
        }
      }

      // Reset scroll state when fill mode changes away from scrolling
      onEffectiveScrollingChanged: {
        if (effectiveScrolling) {
          _firstScrollUpdate = true;
          _updateScrollTarget();
        } else {
          scrollFrameAnim.running = false;
          scrollX = 50;
          scrollY = 50;
        }
      }

      Component.onCompleted: setWallpaperInitial()

      Component.onDestruction: {
        transitionAnimation.stop();
        startupTransitionTimer.stop();
        debounceTimer.stop();
        shaderLoader.active = false;
        currentWallpaper.source = "";
        nextWallpaper.source = "";
      }

      Connections {
        target: Settings.data.wallpaper
        function onFillModeChanged() {
          fillMode = WallpaperService.getFillModeUniform();
        }
      }

      // External state management
      Connections {
        target: WallpaperService
        function onWallpaperChanged(screenName, path) {
          if (screenName === modelData.name) {
            requestPreprocessedWallpaper(path);
          }
        }
      }

      Connections {
        target: CompositorService
        function onDisplayScalesChanged() {
          if (!WallpaperService.isInitialized) {
            return;
          }

          const currentPath = WallpaperService.getWallpaper(modelData.name);
          if (!currentPath || WallpaperService.isSolidColorPath(currentPath)) {
            return;
          }

          if (isStartupTransition) {
            // During startup, just ensure the correct cache exists without visual changes
            const compositorScale = CompositorService.getDisplayScale(modelData.name);
            const targetWidth = Math.round(modelData.width * compositorScale);
            const targetHeight = Math.round(modelData.height * compositorScale);
            ImageCacheService.getLarge(currentPath, targetWidth, targetHeight, function (cachedPath, success) {
              WallpaperService.wallpaperProcessingComplete(modelData.name, currentPath, success ? cachedPath : "");
            });
            return;
          }

          requestPreprocessedWallpaper(currentPath);
        }
      }

      color: "transparent"
      screen: modelData
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "noctalia-wallpaper-" + (screen?.name || "unknown")

      anchors {
        bottom: true
        top: true
        right: true
        left: true
      }

      Timer {
        id: debounceTimer
        interval: 333
        running: false
        repeat: false
        onTriggered: changeWallpaper()
      }

      // Delay startup transition to ensure the compositor has mapped the window
      Timer {
        id: startupTransitionTimer
        interval: 100
        running: false
        repeat: false
        onTriggered: _executeStartupTransition()
      }

      Image {
        id: currentWallpaper

        source: ""
        smooth: true
        mipmap: false
        visible: false
        cache: true // Cached so Overview can share the same texture
        asynchronous: true
        onStatusChanged: {
          if (status === Image.Error) {
            Logger.w("Current wallpaper failed to load:", source);
          } else if (status === Image.Ready && !wallpaperReady) {
            wallpaperReady = true;
          }
        }
      }

      Image {
        id: nextWallpaper

        property bool pendingTransition: false

        source: ""
        smooth: true
        mipmap: false
        visible: false
        cache: false // Not cached - temporary during transitions
        asynchronous: true
        onStatusChanged: {
          if (status === Image.Error) {
            Logger.w("Next wallpaper failed to load:", source);
            pendingTransition = false;
          } else if (status === Image.Ready) {
            if (!wallpaperReady) {
              wallpaperReady = true;
            }
            if (pendingTransition) {
              pendingTransition = false;
              currentWallpaper.asynchronous = false;
              transitionAnimation.start();
            }
          }
        }
      }

      // Dynamic shader loader - only loads the active transition shader
      Loader {
        id: shaderLoader
        anchors.fill: parent
        active: !root.effectiveScrolling

        sourceComponent: {
          switch (transitionType) {
          case "wipe":
            return wipeShaderComponent;
          case "disc":
            return discShaderComponent;
          case "stripes":
            return stripesShaderComponent;
          case "pixelate":
            return pixelateShaderComponent;
          case "honeycomb":
            return honeycombShaderComponent;
          case "fade":
          case "none":
          default:
            return fadeShaderComponent;
          }
        }
      }

      // Parallax shader loader - active only in scrolling mode
      Loader {
        id: parallaxLoader
        anchors.fill: parent
        active: root.effectiveScrolling
        sourceComponent: ShaderEffect {
          property variant source: currentWallpaper
          property real scrollU: root.scrollX
          property real scrollV: root.scrollY
          property real imageWidth: currentWallpaper.sourceSize.width
          property real imageHeight: currentWallpaper.sourceSize.height
          property real screenWidth: width
          property real screenHeight: height
          fragmentShader: Qt.resolvedUrl(Quickshell.shellDir + "/Shaders/qsb/wp_parallax.frag.qsb")
        }
      }

      // Fade or None transition shader component
      Component {
        id: fadeShaderComponent
        ShaderEffect {
          anchors.fill: parent

          property variant source1: currentWallpaper
          property variant source2: nextWallpaper
          property real progress: root.transitionProgress

          // Fill mode properties
          property real fillMode: root.fillMode
          property vector4d fillColor: root.fillColor
          property real imageWidth1: source1.sourceSize.width
          property real imageHeight1: source1.sourceSize.height
          property real imageWidth2: source2.sourceSize.width
          property real imageHeight2: source2.sourceSize.height
          property real screenWidth: width
          property real screenHeight: height

          // Solid color mode
          property real isSolid1: root.isSolid1 ? 1.0 : 0.0
          property real isSolid2: root.isSolid2 ? 1.0 : 0.0
          property vector4d solidColor1: root.solidColor1
          property vector4d solidColor2: root.solidColor2

          // Scrolling parallax
          property real scrollU: root.scrollX
          property real scrollV: root.scrollY

          fragmentShader: Qt.resolvedUrl(Quickshell.shellDir + "/Shaders/qsb/wp_fade.frag.qsb")
        }
      }

      // Wipe transition shader component
      Component {
        id: wipeShaderComponent
        ShaderEffect {
          anchors.fill: parent

          property variant source1: currentWallpaper
          property variant source2: nextWallpaper
          property real progress: root.transitionProgress
          property real smoothness: root.edgeSmoothness
          property real direction: root.wipeDirection

          // Fill mode properties
          property real fillMode: root.fillMode
          property vector4d fillColor: root.fillColor
          property real imageWidth1: source1.sourceSize.width
          property real imageHeight1: source1.sourceSize.height
          property real imageWidth2: source2.sourceSize.width
          property real imageHeight2: source2.sourceSize.height
          property real screenWidth: width
          property real screenHeight: height

          // Solid color mode
          property real isSolid1: root.isSolid1 ? 1.0 : 0.0
          property real isSolid2: root.isSolid2 ? 1.0 : 0.0
          property vector4d solidColor1: root.solidColor1
          property vector4d solidColor2: root.solidColor2

          // Scrolling parallax
          property real scrollU: root.scrollX
          property real scrollV: root.scrollY

          fragmentShader: Qt.resolvedUrl(Quickshell.shellDir + "/Shaders/qsb/wp_wipe.frag.qsb")
        }
      }

      // Disc reveal transition shader component
      Component {
        id: discShaderComponent
        ShaderEffect {
          anchors.fill: parent

          property variant source1: currentWallpaper
          property variant source2: nextWallpaper
          property real progress: root.transitionProgress
          property real smoothness: root.edgeSmoothness
          property real aspectRatio: root.width / root.height
          property real centerX: root.discCenterX
          property real centerY: root.discCenterY

          // Fill mode properties
          property real fillMode: root.fillMode
          property vector4d fillColor: root.fillColor
          property real imageWidth1: source1.sourceSize.width
          property real imageHeight1: source1.sourceSize.height
          property real imageWidth2: source2.sourceSize.width
          property real imageHeight2: source2.sourceSize.height
          property real screenWidth: width
          property real screenHeight: height

          // Solid color mode
          property real isSolid1: root.isSolid1 ? 1.0 : 0.0
          property real isSolid2: root.isSolid2 ? 1.0 : 0.0
          property vector4d solidColor1: root.solidColor1
          property vector4d solidColor2: root.solidColor2

          // Scrolling parallax
          property real scrollU: root.scrollX
          property real scrollV: root.scrollY

          fragmentShader: Qt.resolvedUrl(Quickshell.shellDir + "/Shaders/qsb/wp_disc.frag.qsb")
        }
      }

      // Diagonal stripes transition shader component
      Component {
        id: stripesShaderComponent
        ShaderEffect {
          anchors.fill: parent

          property variant source1: currentWallpaper
          property variant source2: nextWallpaper
          property real progress: root.transitionProgress
          property real smoothness: root.edgeSmoothness
          property real aspectRatio: root.width / root.height
          property real stripeCount: root.stripesCount
          property real angle: root.stripesAngle

          // Fill mode properties
          property real fillMode: root.fillMode
          property vector4d fillColor: root.fillColor
          property real imageWidth1: source1.sourceSize.width
          property real imageHeight1: source1.sourceSize.height
          property real imageWidth2: source2.sourceSize.width
          property real imageHeight2: source2.sourceSize.height
          property real screenWidth: width
          property real screenHeight: height

          // Solid color mode
          property real isSolid1: root.isSolid1 ? 1.0 : 0.0
          property real isSolid2: root.isSolid2 ? 1.0 : 0.0
          property vector4d solidColor1: root.solidColor1
          property vector4d solidColor2: root.solidColor2

          // Scrolling parallax
          property real scrollU: root.scrollX
          property real scrollV: root.scrollY

          fragmentShader: Qt.resolvedUrl(Quickshell.shellDir + "/Shaders/qsb/wp_stripes.frag.qsb")
        }
      }

      // Pixelate transition shader component
      Component {
        id: pixelateShaderComponent
        ShaderEffect {
          anchors.fill: parent

          property variant source1: currentWallpaper
          property variant source2: nextWallpaper
          property real progress: root.transitionProgress
          property real maxBlockSize: root.pixelateMaxBlockSize

          // Fill mode properties
          property real fillMode: root.fillMode
          property vector4d fillColor: root.fillColor
          property real imageWidth1: source1.sourceSize.width
          property real imageHeight1: source1.sourceSize.height
          property real imageWidth2: source2.sourceSize.width
          property real imageHeight2: source2.sourceSize.height
          property real screenWidth: width
          property real screenHeight: height

          // Solid color mode
          property real isSolid1: root.isSolid1 ? 1.0 : 0.0
          property real isSolid2: root.isSolid2 ? 1.0 : 0.0
          property vector4d solidColor1: root.solidColor1
          property vector4d solidColor2: root.solidColor2

          // Scrolling parallax
          property real scrollU: root.scrollX
          property real scrollV: root.scrollY

          fragmentShader: Qt.resolvedUrl(Quickshell.shellDir + "/Shaders/qsb/wp_pixelate.frag.qsb")
        }
      }

      // Honeycomb transition shader component
      Component {
        id: honeycombShaderComponent
        ShaderEffect {
          anchors.fill: parent

          property variant source1: currentWallpaper
          property variant source2: nextWallpaper
          property real progress: root.transitionProgress
          property real cellSize: root.honeycombCellSize
          property real centerX: root.honeycombCenterX
          property real centerY: root.honeycombCenterY
          property real aspectRatio: root.width / root.height

          // Fill mode properties
          property real fillMode: root.fillMode
          property vector4d fillColor: root.fillColor
          property real imageWidth1: source1.sourceSize.width
          property real imageHeight1: source1.sourceSize.height
          property real imageWidth2: source2.sourceSize.width
          property real imageHeight2: source2.sourceSize.height
          property real screenWidth: width
          property real screenHeight: height

          // Solid color mode
          property real isSolid1: root.isSolid1 ? 1.0 : 0.0
          property real isSolid2: root.isSolid2 ? 1.0 : 0.0
          property vector4d solidColor1: root.solidColor1
          property vector4d solidColor2: root.solidColor2

          // Scrolling parallax
          property real scrollU: root.scrollX
          property real scrollV: root.scrollY

          fragmentShader: Qt.resolvedUrl(Quickshell.shellDir + "/Shaders/qsb/wp_honeycomb.frag.qsb")
        }
      }

      // Animation for the transition progress
      NumberAnimation {
        id: transitionAnimation
        target: root
        property: "transitionProgress"
        from: 0.0
        to: 1.0
        duration: Settings.data.wallpaper.transitionDuration
        easing.type: Easing.InOutCubic
        onFinished: {
          // Clear the tracking of what we're transitioning to
          transitioningToOriginalPath = "";

          // Transfer solid color state from next to current
          isSolid1 = isSolid2;
          _solidColor1 = _solidColor2;

          // Assign new image to current BEFORE clearing to prevent flicker
          const tempSource = nextWallpaper.source;
          currentWallpaper.source = tempSource;
          transitionProgress = 0.0;

          // Now clear nextWallpaper after currentWallpaper has the new source
          // Force complete cleanup to free texture memory
          Qt.callLater(() => {
                         nextWallpaper.source = "";
                         isSolid2 = false;
                         Qt.callLater(() => {
                                        currentWallpaper.asynchronous = true;
                                      });
                       });
        }
      }

      // Normalize a path (string or QUrl) to a plain string for comparison.
      // QML Image.source is a url type; comparing url === string can return
      // false even for identical paths. This converts both sides to strings.
      function _pathStr(p) {
        var s = p.toString();
        // QUrl.toString() may add a file:// prefix for local paths
        if (s.startsWith("file://")) {
          return s.substring(7);
        }
        return s;
      }

      // ------------------------------------------------------
      function setWallpaperInitial() {
        // On startup, defer assigning wallpaper until the services are ready
        if (!WallpaperService || !WallpaperService.isInitialized) {
          Qt.callLater(setWallpaperInitial);
          return;
        }
        if (!ImageCacheService || !ImageCacheService.initialized) {
          Qt.callLater(setWallpaperInitial);
          return;
        }

        // Check if we're in solid color mode
        if (Settings.data.wallpaper.useSolidColor) {
          var solidPath = WallpaperService.createSolidColorPath(Settings.data.wallpaper.solidColor.toString());
          futureWallpaper = solidPath;
          performStartupTransition();
          WallpaperService.wallpaperProcessingComplete(modelData.name, solidPath, "");
          return;
        }

        const wallpaperPath = WallpaperService.getWallpaper(modelData.name);

        // Check if the path is a solid color
        if (WallpaperService.isSolidColorPath(wallpaperPath)) {
          futureWallpaper = wallpaperPath;
          performStartupTransition();
          WallpaperService.wallpaperProcessingComplete(modelData.name, wallpaperPath, "");
          return;
        }

        const compositorScale = CompositorService.getDisplayScale(modelData.name);
        const targetWidth = Math.round(modelData.width * compositorScale);
        const targetHeight = Math.round(modelData.height * compositorScale);

        ImageCacheService.getLarge(wallpaperPath, targetWidth, targetHeight, function (cachedPath, success) {
          if (success) {
            futureWallpaper = cachedPath;
          } else {
            // Fallback to original
            futureWallpaper = wallpaperPath;
          }
          performStartupTransition();
          // Pass cached path for blur optimization (already resized)
          WallpaperService.wallpaperProcessingComplete(modelData.name, wallpaperPath, success ? cachedPath : "");
        });
      }

      // ------------------------------------------------------
      function requestPreprocessedWallpaper(originalPath) {
        // If we're already transitioning to this exact wallpaper, skip the request
        if (transitioning && originalPath === transitioningToOriginalPath) {
          return;
        }

        // Store the original path we're working towards
        transitioningToOriginalPath = originalPath;

        // Handle solid color paths - no preprocessing needed
        if (WallpaperService.isSolidColorPath(originalPath)) {
          futureWallpaper = originalPath;
          debounceTimer.restart();
          WallpaperService.wallpaperProcessingComplete(modelData.name, originalPath, "");
          return;
        }

        const compositorScale = CompositorService.getDisplayScale(modelData.name);
        const targetWidth = Math.round(modelData.width * compositorScale);
        const targetHeight = Math.round(modelData.height * compositorScale);

        ImageCacheService.getLarge(originalPath, targetWidth, targetHeight, function (cachedPath, success) {
          // Ignore stale callback if we've moved on to a different wallpaper
          if (originalPath !== transitioningToOriginalPath) {
            return;
          }
          if (success) {
            futureWallpaper = cachedPath;
          } else {
            futureWallpaper = originalPath;
          }

          // Skip transition if the resolved path matches what's already displayed
          if (_pathStr(futureWallpaper) === _pathStr(currentWallpaper.source)) {
            transitioningToOriginalPath = "";
            WallpaperService.wallpaperProcessingComplete(modelData.name, originalPath, success ? cachedPath : "");
            return;
          }

          debounceTimer.restart();
          // Pass cached path for blur optimization (already resized)
          WallpaperService.wallpaperProcessingComplete(modelData.name, originalPath, success ? cachedPath : "");
        });
      }

      // ------------------------------------------------------
      function setWallpaperImmediate(source) {
        transitionAnimation.stop();
        transitionProgress = 0.0;

        // Check if this is a solid color
        var isSolidSource = WallpaperService.isSolidColorPath(source);
        isSolid1 = isSolidSource;
        isSolid2 = false;

        if (isSolidSource) {
          var colorStr = WallpaperService.getSolidColor(source);
          _solidColor1 = colorStr;
          // Clear image sources for memory efficiency
          currentWallpaper.source = "";
          nextWallpaper.source = "";
          if (!wallpaperReady) {
            wallpaperReady = true;
          }
          return;
        }

        // Clear nextWallpaper completely to free texture memory
        nextWallpaper.source = "";
        nextWallpaper.sourceSize = undefined;

        currentWallpaper.source = "";

        Qt.callLater(() => {
                       currentWallpaper.source = source;
                     });
      }

      // ------------------------------------------------------
      function setWallpaperWithTransition(source) {
        // Check if this is a solid color transition
        var isSolidSource = WallpaperService.isSolidColorPath(source);

        // For solid colors, check if we're already showing the same color
        if (isSolidSource && isSolid1) {
          var newColor = WallpaperService.getSolidColor(source);
          if (newColor === _solidColor1.toString()) {
            return;
          }
        }

        // For images, check if source matches (use _pathStr to normalize url vs string)
        if (!isSolidSource && _pathStr(source) === _pathStr(currentWallpaper.source)) {
          return;
        }

        // If we're already transitioning to this same wallpaper, skip
        if (transitioning && source === nextWallpaper.source) {
          return;
        }

        if (transitioning) {
          // We are interrupting a transition - handle cleanup properly
          transitionAnimation.stop();
          transitionProgress = 0;

          // Transfer next state to current
          isSolid1 = isSolid2;
          _solidColor1 = _solidColor2;
          const newCurrentSource = nextWallpaper.source;
          currentWallpaper.source = newCurrentSource;

          // Now clear nextWallpaper after current has the new source
          Qt.callLater(() => {
                         nextWallpaper.source = "";
                         isSolid2 = false;

                         // Now set the next wallpaper after a brief delay
                         Qt.callLater(() => {
                                        _startTransitionTo(source, isSolidSource);
                                      });
                       });
          return;
        }

        _startTransitionTo(source, isSolidSource);
      }

      // Helper to start transition to a new source
      function _startTransitionTo(source, isSolidSource) {
        isSolid2 = isSolidSource;

        if (isSolidSource) {
          var colorStr = WallpaperService.getSolidColor(source);
          _solidColor2 = colorStr;
          // No image to load, start transition immediately
          nextWallpaper.source = "";
          if (!wallpaperReady) {
            wallpaperReady = true;
          }
          currentWallpaper.asynchronous = false;
          transitionAnimation.start();
        } else {
          nextWallpaper.source = source;
          if (nextWallpaper.status === Image.Ready) {
            if (!wallpaperReady) {
              wallpaperReady = true;
            }
            currentWallpaper.asynchronous = false;
            transitionAnimation.start();
          } else {
            nextWallpaper.pendingTransition = true;
          }
        }
      }

      // ------------------------------------------------------
      // Main method that actually trigger the wallpaper change
      function changeWallpaper() {
        // In scroll mode, skip transitions - apply immediately
        if (effectiveScrolling) {
          setWallpaperImmediate(futureWallpaper);
          return;
        }

        // Get the transitionType from the settings
        transitionType = Settings.data.wallpaper.transitionType;

        if (transitionType == "random") {
          var index = Math.floor(Math.random() * allTransitions.length);
          transitionType = allTransitions[index];
        }

        // Ensure the transition type really exists
        if (transitionType !== "none" && !allTransitions.includes(transitionType)) {
          transitionType = "fade";
        }

        //Logger.i("Background", "New wallpaper: ", futureWallpaper, "On:", modelData.name, "Transition:", transitionType)
        switch (transitionType) {
        case "none":
          setWallpaperImmediate(futureWallpaper);
          break;
        case "wipe":
          wipeDirection = Math.random() * 4;
          setWallpaperWithTransition(futureWallpaper);
          break;
        case "disc":
          discCenterX = Math.random();
          discCenterY = Math.random();
          setWallpaperWithTransition(futureWallpaper);
          break;
        case "stripes":
          stripesCount = Math.round(Math.random() * 20 + 4);
          stripesAngle = Math.random() * 360;
          setWallpaperWithTransition(futureWallpaper);
          break;
        case "pixelate":
          pixelateMaxBlockSize = Math.round(Math.random() * 80 + 32);
          setWallpaperWithTransition(futureWallpaper);
          break;
        case "honeycomb":
          honeycombCellSize = Math.random() * 0.04 + 0.02;
          honeycombCenterX = Math.random();
          honeycombCenterY = Math.random();
          setWallpaperWithTransition(futureWallpaper);
          break;
        default:
          setWallpaperWithTransition(futureWallpaper);
          break;
        }
      }

      // ------------------------------------------------------
      // Dedicated function for startup animation
      // Sets up transition params, then defers the actual animation
      // to allow the compositor time to map the window.
      function performStartupTransition() {
        if (Settings.data.wallpaper.skipStartupTransition) {
          setWallpaperImmediate(futureWallpaper);
          isStartupTransition = false;
          return;
        }

        // Get the transitionType from the settings
        transitionType = Settings.data.wallpaper.transitionType;

        if (transitionType == "random") {
          var index = Math.floor(Math.random() * allTransitions.length);
          transitionType = allTransitions[index];
        }

        // Ensure the transition type really exists
        if (transitionType !== "none" && !allTransitions.includes(transitionType)) {
          transitionType = "fade";
        }

        // Pre-compute per-type params so the shader is ready
        switch (transitionType) {
        case "wipe":
          wipeDirection = Math.random() * 4;
          break;
        case "disc":
          // Force center origin for elegant startup animation
          discCenterX = 0.5;
          discCenterY = 0.5;
          break;
        case "stripes":
          stripesCount = Math.round(Math.random() * 20 + 4);
          stripesAngle = Math.random() * 360;
          break;
        case "pixelate":
          pixelateMaxBlockSize = 64.0;
          break;
        case "honeycomb":
          honeycombCellSize = 0.04;
          honeycombCenterX = 0.5;
          honeycombCenterY = 0.5;
          break;
        }

        // Defer the actual transition start so the compositor can map the window
        startupTransitionTimer.start();
      }

      // Actually kick off the startup transition after the delay
      function _executeStartupTransition() {
        if (transitionType === "none") {
          setWallpaperImmediate(futureWallpaper);
        } else {
          setWallpaperWithTransition(futureWallpaper);
        }
        // Mark startup transition complete
        isStartupTransition = false;
      }
    }
  }
}
