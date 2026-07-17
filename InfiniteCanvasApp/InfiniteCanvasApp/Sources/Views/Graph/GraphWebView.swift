import SwiftUI
import WebKit

/// d3-force による力学ネットワークグラフを描く WKWebView ラッパー。
/// - `json`   : NoteGraphBuilder.jsonString の出力({nodes, links})
/// - `search` : 一致ノードを強調・非一致を減光する検索語
/// - `onOpenNote`: ノード(ノート)タップ時に該当ノートを開くコールバック
struct GraphWebView: UIViewRepresentable {
    let json: String
    let search: String
    let onOpenNote: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpenNote: onOpenNote) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "openNote")
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false          // ズーム/パンは d3 側で処理
        webView.scrollView.bounces = false
        context.coordinator.webView = webView
        webView.loadHTMLString(Self.html, baseURL: URL(string: "https://d3js.org/"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpenNote = onOpenNote
        context.coordinator.apply(json: json, search: search)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // メッセージハンドラの参照を解除(リーク防止)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "openNote")
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onOpenNote: (UUID) -> Void
        weak var webView: WKWebView?

        private var isLoaded = false
        private var lastJSON: String?
        private var lastSearch: String?

        init(onOpenNote: @escaping (UUID) -> Void) {
            self.onOpenNote = onOpenNote
        }

        // ページ読み込み完了後に、保留していた最新データを反映する
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let json = lastJSON { pushGraph(json) }
            if let search = lastSearch { pushSearch(search) }
        }

        /// SwiftUI からの更新。前回と変わった項目だけ JS へ送る。
        func apply(json: String, search: String) {
            if json != lastJSON {
                lastJSON = json
                if isLoaded { pushGraph(json) }
            }
            if search != lastSearch {
                lastSearch = search
                if isLoaded { pushSearch(search) }
            }
        }

        private func pushGraph(_ json: String) {
            webView?.evaluateJavaScript("updateGraph(\(json));", completionHandler: nil)
        }

        private func pushSearch(_ term: String) {
            // JS 文字列リテラル内では未エスケープの改行系文字(LF/CR)が構文エラーになる。
            // \n だけでなく \r(古い改行コードやペーストで混入しうる)も置換する。
            let escaped = term
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            webView?.evaluateJavaScript("setSearch(\"\(escaped)\");", completionHandler: nil)
        }

        // JS → Swift: ノードタップ
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "openNote",
                  let idString = message.body as? String,
                  let uuid = UUID(uuidString: idString) else { return }
            onOpenNote(uuid)
        }
    }

    // MARK: - HTML / d3.js テンプレート

    private static let html = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <style>
      html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden;
                   background: transparent; -webkit-user-select: none; user-select: none;
                   -webkit-tap-highlight-color: transparent; }
      #graph { width: 100vw; height: 100vh; display: block; touch-action: none; }
      .link { stroke: #9aa0a6; stroke-opacity: 0.5; }
      .node circle { fill: #4a90d9; stroke: #ffffff; stroke-width: 1.5px; cursor: pointer; }
      .node text { font-family: -apple-system, system-ui, sans-serif; font-size: 11px;
                   fill: #3c4043; pointer-events: none; text-anchor: middle;
                   paint-order: stroke; stroke: rgba(255,255,255,0.85); stroke-width: 2.5px; }
      .node.dimmed { opacity: 0.15; }
      .node.match circle { fill: #ff9500; }
      #empty { position: absolute; top: 50%; left: 0; right: 0; transform: translateY(-50%);
               text-align: center; font-family: -apple-system, system-ui, sans-serif;
               color: #9aa0a6; font-size: 15px; display: none; }
      @media (prefers-color-scheme: dark) {
        .link { stroke: #5f6368; }
        .node circle { stroke: #202124; }
        .node text { fill: #e8eaed; stroke: rgba(0,0,0,0.7); }
      }
    </style>
    <script src="https://d3js.org/d3.v7.min.js"></script>
    </head>
    <body>
    <svg id="graph"></svg>
    <div id="empty">ノートリンクでノートをつなぐと<br>ここに関係グラフが表示されます</div>
    <script>
    (function () {
      var svg = d3.select("#graph");
      var width = window.innerWidth, height = window.innerHeight;
      svg.attr("viewBox", [0, 0, width, height]);
      var container = svg.append("g");
      var linkLayer = container.append("g").attr("class", "links");
      var nodeLayer = container.append("g").attr("class", "nodes");
      var emptyLabel = document.getElementById("empty");

      var zoom = d3.zoom().scaleExtent([0.15, 4]).on("zoom", function (event) {
        container.attr("transform", event.transform);
      });
      svg.call(zoom);

      var simulation = d3.forceSimulation()
        .force("charge", d3.forceManyBody().strength(-150))
        .force("link", d3.forceLink().id(function (d) { return d.id; }).distance(60))
        .force("center", d3.forceCenter(width / 2, height / 2))
        .force("collide", d3.forceCollide().radius(function (d) { return radius(d) + 6; }))
        .on("tick", ticked);

      // データ適用のたびに一度だけ全体をビューへ収める(少数/未接続ノードでも右下隅に
      // 寄らず中央に来るように)。収束(end)まで待つと数秒かかるため、レイアウトが
      // 形になる短時間後にフィットする。以降 forceCenter が中央を保つ。
      var fitTimer = null;
      function scheduleFit() {
        if (fitTimer) clearTimeout(fitTimer);
        fitTimer = setTimeout(fitToView, 500);
      }

      // 全ノードの外接矩形をビューポート中央へフィットさせる(拡大は最大2倍まで)。
      function fitToView() {
        if (!nodes.length) return;
        var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
        nodes.forEach(function (n) {
          if (n.x < minX) minX = n.x; if (n.x > maxX) maxX = n.x;
          if (n.y < minY) minY = n.y; if (n.y > maxY) maxY = n.y;
        });
        var w = window.innerWidth, h = window.innerHeight, pad = 60;
        var gw = Math.max(maxX - minX, 1), gh = Math.max(maxY - minY, 1);
        var scale = Math.max(0.15, Math.min((w - pad * 2) / gw, (h - pad * 2) / gh, 2));
        var cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
        var t = d3.zoomIdentity.translate(w / 2 - scale * cx, h / 2 - scale * cy).scale(scale);
        svg.transition().duration(400).call(zoom.transform, t);
      }

      var nodes = [], links = [];
      var linkSel = linkLayer.selectAll("line");
      var nodeSel = nodeLayer.selectAll("g.node");

      function radius(d) { return 6 + Math.min(d.degree || 0, 8) * 2; }

      function ticked() {
        linkSel
          .attr("x1", function (d) { return d.source.x; })
          .attr("y1", function (d) { return d.source.y; })
          .attr("x2", function (d) { return d.target.x; })
          .attr("y2", function (d) { return d.target.y; });
        nodeSel.attr("transform", function (d) { return "translate(" + d.x + "," + d.y + ")"; });
      }

      // ドラッグで移動。移動が閾値未満ならタップとみなしてノートを開く。
      function makeDrag() {
        var moved = false, sx = 0, sy = 0;
        function started(event, d) {
          moved = false; sx = event.x; sy = event.y;
          if (!event.active) simulation.alphaTarget(0.3).restart();
          d.fx = d.x; d.fy = d.y;
        }
        function dragged(event, d) {
          if (Math.hypot(event.x - sx, event.y - sy) > 4) moved = true;
          d.fx = event.x; d.fy = event.y;
        }
        function ended(event, d) {
          if (!event.active) simulation.alphaTarget(0);
          d.fx = null; d.fy = null;
          if (!moved) openNote(d);
        }
        return d3.drag().on("start", started).on("drag", dragged).on("end", ended);
      }

      function openNote(d) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.openNote) {
          window.webkit.messageHandlers.openNote.postMessage(d.id);
        }
      }

      // Swift から呼ばれる: グラフデータの適用(ノード位置は可能な限り維持)
      window.updateGraph = function (data) {
        var previous = new Map(nodes.map(function (d) { return [d.id, d]; }));
        nodes = data.nodes.map(function (d) {
          var old = previous.get(d.id);
          return Object.assign(old || {}, d);
        });
        links = data.links.map(function (d) { return { source: d.source, target: d.target }; });

        emptyLabel.style.display = nodes.length === 0 ? "block" : "none";

        linkSel = linkLayer.selectAll("line").data(links, function (d) {
          var s = d.source.id || d.source, t = d.target.id || d.target;
          return s + "->" + t;
        });
        linkSel.exit().remove();
        linkSel = linkSel.enter().append("line").attr("class", "link").merge(linkSel);

        nodeSel = nodeLayer.selectAll("g.node").data(nodes, function (d) { return d.id; });
        nodeSel.exit().remove();
        var enter = nodeSel.enter().append("g").attr("class", "node").call(makeDrag());
        enter.append("circle");
        enter.append("text");
        nodeSel = enter.merge(nodeSel);
        nodeSel.select("circle").attr("r", radius);
        nodeSel.select("text")
          .text(function (d) { return d.title; })
          .attr("dy", function (d) { return -radius(d) - 4; });

        simulation.nodes(nodes);
        simulation.force("link").links(links);
        simulation.alpha(0.9).restart();
        scheduleFit();                    // レイアウトが形になったら中央フィット
      };

      // Swift から呼ばれる: 検索語で強調/減光
      window.setSearch = function (term) {
        term = (term || "").toLowerCase();
        nodeSel.classed("dimmed", function (d) {
          return term !== "" && d.title.toLowerCase().indexOf(term) === -1;
        });
        nodeSel.classed("match", function (d) {
          return term !== "" && d.title.toLowerCase().indexOf(term) !== -1;
        });
      };

      window.addEventListener("resize", function () {
        width = window.innerWidth; height = window.innerHeight;
        svg.attr("viewBox", [0, 0, width, height]);
        simulation.force("center", d3.forceCenter(width / 2, height / 2));
        simulation.alpha(0.3).restart();
      });
    })();
    </script>
    </body>
    </html>
    """
}
