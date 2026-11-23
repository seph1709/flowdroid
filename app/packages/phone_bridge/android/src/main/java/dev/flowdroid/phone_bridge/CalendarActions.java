package dev.flowdroid.phone_bridge;

import android.Manifest;
import android.content.ContentUris;
import android.content.ContentValues;
import android.content.Context;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.provider.CalendarContract;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;

/**
 * The phone's own calendars (every account the phone syncs: Google, Exchange,
 * Samsung, local), read and written through CalendarContract.
 */
final class CalendarActions {
    private CalendarActions() {}

    static boolean canRead(Context context) {
        return context.checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED;
    }

    static boolean canWrite(Context context) {
        return context.checkSelfPermission(Manifest.permission.WRITE_CALENDAR) == PackageManager.PERMISSION_GRANTED;
    }

    /**
     * Events between [from] and [to] (epoch ms), repeating ones included, in
     * calendars whose name contains [calendar] (any when empty), by start time.
     */
    static List<Map<String, Object>> events(Context context, long from, long to, String calendar) {
        Uri.Builder uri = CalendarContract.Instances.CONTENT_URI.buildUpon();
        ContentUris.appendId(uri, from);
        ContentUris.appendId(uri, to);
        String[] columns = {
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.EVENT_LOCATION,
            CalendarContract.Instances.DESCRIPTION,
            CalendarContract.Instances.CALENDAR_DISPLAY_NAME,
            CalendarContract.Instances.STATUS,
            CalendarContract.Instances.AVAILABILITY,
        };
        List<Map<String, Object>> out = new ArrayList<>();
        String filter = calendar == null ? "" : calendar.trim().toLowerCase(Locale.ROOT);
        try (Cursor c = context.getContentResolver().query(
                uri.build(), columns, null, null, CalendarContract.Instances.BEGIN + " ASC")) {
            if (c == null) return out;
            while (c.moveToNext()) {
                String calendarName = c.isNull(7) ? "" : c.getString(7);
                if (!filter.isEmpty() && !calendarName.toLowerCase(Locale.ROOT).contains(filter)) continue;
                if (!c.isNull(8) && c.getInt(8) == CalendarContract.Instances.STATUS_CANCELED) continue;
                Map<String, Object> e = new HashMap<>();
                e.put("id", String.valueOf(c.getLong(0)));
                e.put("title", c.isNull(1) ? "" : c.getString(1));
                e.put("start", c.getLong(2));
                e.put("end", c.getLong(3));
                e.put("allDay", c.getInt(4) == 1);
                e.put("location", c.isNull(5) ? "" : c.getString(5));
                e.put("description", c.isNull(6) ? "" : c.getString(6));
                e.put("calendar", calendarName);
                // "Free" events (e.g. reminders, holidays) don't block free time.
                e.put("busy", c.isNull(9) || c.getInt(9) != CalendarContract.Events.AVAILABILITY_FREE);
                out.add(e);
            }
        }
        return out;
    }

    /**
     * Adds an event: [start] and [end] are epoch ms (for all-day events, midnight
     * UTC of the first day and of the day after the last). Returns its id, or
     * throws with a message.
     */
    static String create(Context context, Map<String, Object> event) {
        long calendarId = calendarFor(context, str(event.get("calendar")));
        boolean allDay = Boolean.TRUE.equals(event.get("allDay"));
        ContentValues v = new ContentValues();
        v.put(CalendarContract.Events.CALENDAR_ID, calendarId);
        v.put(CalendarContract.Events.TITLE, str(event.get("title")));
        v.put(CalendarContract.Events.DTSTART, num(event.get("start")));
        v.put(CalendarContract.Events.DTEND, num(event.get("end")));
        v.put(CalendarContract.Events.ALL_DAY, allDay ? 1 : 0);
        v.put(CalendarContract.Events.EVENT_TIMEZONE, allDay ? "UTC" : TimeZone.getDefault().getID());
        String location = str(event.get("location"));
        if (!location.isEmpty()) v.put(CalendarContract.Events.EVENT_LOCATION, location);
        String description = str(event.get("description"));
        if (!description.isEmpty()) v.put(CalendarContract.Events.DESCRIPTION, description);
        Uri created = context.getContentResolver().insert(CalendarContract.Events.CONTENT_URI, v);
        if (created == null) throw new IllegalStateException("the calendar did not accept the event");
        return String.valueOf(ContentUris.parseId(created));
    }

    /** A calendar new events may go in: the one whose name contains [name], else the main one. */
    private static long calendarFor(Context context, String name) {
        String[] columns = {
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.IS_PRIMARY,
            CalendarContract.Calendars.VISIBLE,
        };
        String writable = CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL + " >= "
            + CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR;
        String filter = name.trim().toLowerCase(Locale.ROOT);
        long first = -1;
        long primary = -1;
        try (Cursor c = context.getContentResolver().query(
                CalendarContract.Calendars.CONTENT_URI, columns, writable, null, null)) {
            while (c != null && c.moveToNext()) {
                long id = c.getLong(0);
                String display = c.isNull(1) ? "" : c.getString(1);
                if (!filter.isEmpty()) {
                    if (display.toLowerCase(Locale.ROOT).contains(filter)) return id;
                    continue;
                }
                if (first < 0 && (c.isNull(3) || c.getInt(3) == 1)) first = id;
                if (primary < 0 && !c.isNull(2) && c.getInt(2) == 1) primary = id;
            }
        }
        if (!filter.isEmpty()) throw new IllegalStateException("no calendar you can add to is called “" + name.trim() + "”");
        if (primary >= 0) return primary;
        if (first >= 0) return first;
        throw new IllegalStateException("this phone has no calendar FlowDroid can add events to");
    }

    private static String str(Object o) {
        return o == null ? "" : o.toString();
    }

    private static long num(Object o) {
        return o instanceof Number ? ((Number) o).longValue() : 0;
    }
}
