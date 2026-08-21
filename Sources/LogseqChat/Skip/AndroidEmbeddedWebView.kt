package logseq.chat

import android.webkit.WebView

object AndroidEmbeddedWebView {
    fun load(view: WebView, url: String, referer: String?) {
        if (referer == null) {
            view.loadUrl(url)
        } else {
            view.loadUrl(url, mapOf("Referer" to referer))
        }
    }
}
