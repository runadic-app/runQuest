fileprivate struct MapView: UIViewRepresentable  {
    @ObservedObject var model: ActivityProgressGraphModel
    @Binding var selectedClusterIdx: Int

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.mapType = .mutedStandard
        mapView.preferredConfiguration.elevationStyle = .flat
        mapView.isPitchEnabled = false
        mapView.showsUserLocation = false
        mapView.showsBuildings = false
        mapView.overrideUserInterfaceStyle = .dark
        mapView.pointOfInterestFilter = MKPointOfInterestFilter.excludingAll
        mapView.setUserTrackingMode(.none, animated: false)
        mapView.delegate = context.coordinator
        mapView.alpha = 0.0
        context.coordinator.mkView = mapView

        model.$coordinateClusters
            .receive(on: DispatchQueue.main)
            .sink { _ in
                selectedClusterIdx = 0
            }.store(in: &context.coordinator.subscribers)

        model.$viewVisible
            .receive(on: DispatchQueue.main)
            .sink { visible in
                if visible {
                    addPolylines(mapView)
                } else {
                    mapView.removeOverlays(mapView.overlays)
                }
            }.store(in: &context.coordinator.subscribers)

        return mapView
    }

    private func addPolylines(_ mapView: MKMapView) {
        if model.coordinateClusters.isEmpty {
            return
        }

        Task(priority: .userInitiated) {
            mapView.removeOverlays(mapView.overlays)
            model.coordinateClusters[selectedClusterIdx].coordinates.forEach { coordinates in
                coordinates.withUnsafeBufferPointer { pointer in
                    if let base = pointer.baseAddress {
                        let newPolyline = MKPolyline(coordinates: base, count: coordinates.count)
                        mapView.addOverlay(newPolyline)
                    }
                }
            }
        }
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        if model.coordinateClusters.count > selectedClusterIdx {
            addPolylines(uiView)
            let rect = model.coordinateClusters[selectedClusterIdx].rect
            if rect != context.coordinator.displayedRect {
                let edgePadding = UIEdgeInsets(top: 180.0,
                                               left: 25.0,
                                               bottom: UIScreen.main.bounds.height * 0.4,
                                               right: 25.0)
                uiView.setVisibleMapRect(rect,
                                         edgePadding: edgePadding,
                                         animated: context.coordinator.hasSetInitialRegion)
                context.coordinator.displayedRect = rect
                context.coordinator.resetAnimationTimer()
                context.coordinator.hasSetInitialRegion = true
            }

            context.coordinator.shouldAnimateIn = true
        } else if model.coordinateClusters.isEmpty {
            uiView.removeOverlays(uiView.overlays)
            if context.coordinator.hasSetInitialRegion && model.hasPerformedInitialLoad {
                context.coordinator.shouldAnimateIn = true
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var parent: MapView
        var mkView: MKMapView?
        var subscribers: Set = []
        var hasSetInitialRegion: Bool = false
        var hasInitialFinishedRender: Bool = false
        var displayedRect: MKMapRect?
        var shouldAnimateIn: Bool = false
        var willRender: Bool = false
        private lazy var displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFire))
        private var polylineProgress: CGFloat = 0
        private let lineColor = UIColor.white.withAlphaComponent(0.6)

        init(parent: MapView) {
            self.parent = parent
            super.init()

            self.displayLink.add(to: .main, forMode: .common)
            self.displayLink.add(to: .main, forMode: .tracking)
            self.displayLink.isPaused = false
        }

        func resetAnimationTimer() {
            polylineProgress = -0.05
            displayLinkFire()
            displayLink.isPaused = true
        }

        @objc func displayLinkFire() {
            if polylineProgress <= 1 {
                for overlay in mkView!.overlays {
                    if !overlay.boundingMapRect.intersects(mkView?.visibleMapRect ?? MKMapRect()) {
                        continue
                    }

                    if let polylineRenderer = mkView!.renderer(for: overlay) as? MKPolylineRenderer {
                        polylineRenderer.strokeEnd = RouteScene.easeOutQuad(x: polylineProgress).clamped(to: 0...1)
                        polylineRenderer.strokeColor = polylineProgress <= 0.01 ? .clear : lineColor
                        polylineRenderer.blendMode = .destinationAtop
                        polylineRenderer.setNeedsDisplay()
                    }
                }
                
                polylineProgress += 0.01
            }
        }

        func lineWidth(for mapView: MKMapView) -> CGFloat {
            let visibleWidth = mapView.visibleMapRect.width
            return CGFloat(-0.00000975 * visibleWidth + 2.7678715).clamped(to: 1.5...2.5)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let stroke = lineWidth(for: mapView)
            if let routePolyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: routePolyline)
                renderer.strokeColor = displayLink.isPaused ? .clear : lineColor
                renderer.lineWidth = stroke
                renderer.strokeEnd = displayLink.isPaused ? 0 : 1
                renderer.blendMode = .destinationAtop
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }

            return MKOverlayRenderer()
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            let stroke = lineWidth(for: mapView)
            for overlay in mkView!.overlays {
                if !overlay.boundingMapRect.intersects(mkView?.visibleMapRect ?? MKMapRect()) {
                    continue
                }

                if let polylineRenderer = mkView!.renderer(for: overlay) as? MKPolylineRenderer {
                    polylineRenderer.lineWidth = stroke
                }
            }
        }

        func mapViewWillStartRenderingMap(_ mapView: MKMapView) {
            willRender = true
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if willRender {
                return
            }

            displayLink.isPaused = false
        }

        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            if fullyRendered {
                displayLink.isPaused = false
                willRender = false

                if shouldAnimateIn {
                    UIView.animate(withDuration: 0.3) {
                        mapView.alpha = 1.0
                    }
                    shouldAnimateIn = false
                }
            }
        }
    }
}