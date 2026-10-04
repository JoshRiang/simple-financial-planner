package com.joshua.vector_finance

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * SpendLog home-screen widget: how much runway is left.
 */
class RunwayWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.widget_runway)
            views.setTextViewText(R.id.widget_primary,
                context.getString(R.string.widget_loading))
            mgr.updateAppWidget(id, views)
            // The fetch runs in onReceive under goAsync(): a thread started
            // here can be killed the moment onUpdate returns, which made
            // every fetch fail and the widget show "Server unreachable".
        }
    }


    /**
     * The fetch runs here, not in onUpdate, so that goAsync() can hold the
     * broadcast open. A thread started from onUpdate is killed with the process
     * as soon as onUpdate returns, which made the request die and the widget
     * report "Server unreachable" while the server was healthy.
     */
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action != AppWidgetManager.ACTION_APPWIDGET_UPDATE) return
        val pending = goAsync()
        val mgr = AppWidgetManager.getInstance(context)
        val ids = mgr.getAppWidgetIds(
            android.content.ComponentName(context, javaClass))
        thread {
            try {
                for (id in ids) refresh(context, mgr, id)
            } finally {
                pending.finish()
            }
        }
    }

    private fun refresh(context: Context, mgr: AppWidgetManager, id: Int) {
        val views = RemoteViews(context.packageName, R.layout.widget_runway)
        try {
            val o = JSONObject(httpGet(context, "/finance"))
            val runway = if (o.isNull("runway_days")) null else o.optInt("runway_days")
            val free = if (o.isNull("free_today")) null else o.optDouble("free_today", 0.0)
            val currency = o.optString("currency", "IDR")
            views.setTextViewText(R.id.widget_primary,
                if (runway == null) "-- days" else runway.toString() + " days")
            views.setTextViewText(R.id.widget_secondary,
                if (free == null) "No spending logged yet"
                else fmt(free) + " " + currency + " free today")
            views.setTextViewText(R.id.widget_badge, "RUNWAY")
        } catch (e: Exception) {
            // Only a transport failure means the server is unreachable; any
            // other exception is a bug here and must not be reported as one.
            val offline = e is java.io.IOException
            views.setTextViewText(R.id.widget_primary,
                if (offline) context.getString(R.string.widget_offline)
                else "Widget bug: " + (e.message ?: e.javaClass.simpleName))
            views.setTextViewText(R.id.widget_secondary,
                if (offline) context.getString(R.string.widget_offline_hint) else "")
            views.setTextViewText(R.id.widget_badge, "")
        }
        val open = Intent(context, MainActivity::class.java)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        views.setOnClickPendingIntent(R.id.widget_root,
            PendingIntent.getActivity(context, 0, open, flags))
        mgr.updateAppWidget(id, views)
    }


    /** Group digits so a 7-figure amount stays readable in a narrow widget. */
    private fun fmt(v: Double): String = String.format("%,.0f", v)

    /** Short label for a priority. 1 is the most important. */
    private fun priLabel(p: Int): String = when (p) {
        1 -> "P1"
        2 -> "P2"
        3 -> "P3"
        4 -> "P4"
        else -> "P5"
    }

    /** Badge colour for a priority. Paired with priLabel so meaning is never
     *  carried by colour alone. */
    private fun priColor(p: Int): Int = when (p) {
        1 -> 0xFFEF4444.toInt()
        2 -> 0xFFF59E0B.toInt()
        3 -> 0xFF6366F1.toInt()
        4 -> 0xFF9CA3AF.toInt()
        else -> 0xFFC7C7CC.toInt()
    }

    /**
     * Endpoints tried in order, after the configured one.
     *
     * The public URL is the only endpoint that works away from home, but it can
     * be unreachable while a private address still answers -- Tailscale DNS up
     * with the tunnel down, a captive portal, a slow cold start. The app has
     * this failover and works; the widget did not, which is why the app
     * recovered while the widget kept reporting "Server unreachable".
     */
    private val FALLBACK_BASES = listOf(
        "http://10.11.11.235:8790",
        "http://100.89.180.23:8790",
    )

    private fun candidateBases(context: Context): List<String> {
        val primary = context.getString(R.string.vector_api_base).trimEnd('/')
        return (listOf(primary) + FALLBACK_BASES)
            .map { it.trimEnd('/') }
            .distinct()
    }

    private fun httpGet(context: Context, path: String): String =
        http(context, "GET", path, null)

    private fun httpPost(context: Context, path: String): String =
        http(context, "POST", path, "{}")

    /**
     * HTTP entry point with endpoint failover. A widget provider runs on the
     * main thread, so every caller is responsible for being off it.
     *
     * Only a transport failure (IOException) moves on to the next endpoint: if
     * the server answered at all, another address would answer the same way.
     */
    private fun http(context: Context, method: String, path: String,
                     body: String?): String {
        var lastError: java.io.IOException? = null
        for (base in candidateBases(context)) {
            try {
                return httpOnce(context, base, method, path, body)
            } catch (e: java.io.IOException) {
                lastError = e
            }
        }
        throw java.io.IOException(
            "no endpoint reachable: " + (lastError?.message ?: "unknown"))
    }

    /** One request against one base. */
    private fun httpOnce(context: Context, base: String, method: String,
                         path: String, body: String?): String {
        val userId = context.getString(R.string.vector_user_id)
        val key = context.getString(R.string.vector_api_key)
        val conn = (URL(base + path).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            // 5s, not 8s: an appwidget update is time-limited, and a dead
            // private address must not eat the budget before the live one.
            connectTimeout = 5000
            readTimeout = 5000
            setRequestProperty("X-User-Id", userId)
            setRequestProperty("Accept", "application/json")
            if (key.isNotEmpty()) setRequestProperty("X-Api-Key", key)
            if (body != null) {
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
        }
        try {
            if (body != null) {
                conn.outputStream.use { it.write(body.toByteArray()) }
            }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            return stream?.bufferedReader()?.use { it.readText() } ?: ""
        } finally {
            conn.disconnect()
        }
    }

    /**
     * Report a widget event to the server.
     *
     * The widget shows "Server unreachable" for every exception it catches,
     * which hides a code bug behind a network diagnosis. Beaconing the real
     * exception is the only way to tell the two apart on a device. Runs
     * SYNCHRONOUSLY: every caller is already off the main thread, and a nested
     * thread could outlive goAsync()'s finisher and be killed before sending.
     */
    private fun beacon(context: Context, stage: String, detail: String) {
        // Tries every candidate endpoint, like the real requests do. The first
        // version used only the primary URL, so when the primary was the
        // unreachable one the beacon failed too and the widget's failure was
        // never reported anywhere - the exact moment it was needed.
        for (base in candidateBases(context)) {
            try {
                val url = java.net.URL(base.trimEnd('/') + "/diag?stage=" +
                    java.net.URLEncoder.encode(stage, "UTF-8") + "&detail=" +
                    java.net.URLEncoder.encode(detail.take(500), "UTF-8"))
                val conn = (url.openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    connectTimeout = 4000
                    readTimeout = 4000
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json")
                    setRequestProperty("X-User-Id",
                        context.getString(R.string.vector_user_id))
                }
                conn.outputStream.use { it.write("{}".toByteArray()) }
                conn.responseCode
                conn.disconnect()
                return
            } catch (e: Exception) {
                // Try the next endpoint; never let the diagnostic become the
                // failure it is trying to report.
            }
        }
    }


}
