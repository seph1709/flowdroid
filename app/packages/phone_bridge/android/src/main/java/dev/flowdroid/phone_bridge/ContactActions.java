package dev.flowdroid.phone_bridge;

import android.content.ContentProviderOperation;
import android.content.ContentProviderResult;
import android.content.ContentUris;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.provider.ContactsContract;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Finds and adds the phone's contacts. */
final class ContactActions {
    private ContactActions() {}

    /**
     * Contacts matching [query]: by phone number when it looks like one (so
     * "+1 555 0100" finds "5550100"), otherwise by name. At most [limit].
     */
    static List<Map<String, Object>> find(Context context, String query, int limit) {
        String q = query == null ? "" : query.trim();
        int digits = 0;
        for (char ch : q.toCharArray()) if (Character.isDigit(ch)) digits++;
        boolean number = digits >= 3 && digits * 2 >= q.replace(" ", "").length();
        Uri lookup = number
            ? Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(q))
            : Uri.withAppendedPath(ContactsContract.Contacts.CONTENT_FILTER_URI, Uri.encode(q));
        String idColumn = number ? ContactsContract.PhoneLookup.CONTACT_ID : ContactsContract.Contacts._ID;
        // Before Android 7, PhoneLookup's id column is _ID.
        if (number && android.os.Build.VERSION.SDK_INT < 24) idColumn = ContactsContract.PhoneLookup._ID;
        Map<Long, String> found = new LinkedHashMap<>();
        try (Cursor c = context.getContentResolver().query(
                lookup, new String[] {idColumn, ContactsContract.Contacts.DISPLAY_NAME}, null, null, null)) {
            while (c != null && c.moveToNext() && found.size() < limit) {
                found.put(c.getLong(0), c.isNull(1) ? "" : c.getString(1));
            }
        }
        List<Map<String, Object>> out = new ArrayList<>();
        for (Map.Entry<Long, String> e : found.entrySet()) {
            Map<String, Object> contact = new HashMap<>();
            contact.put("id", String.valueOf(e.getKey()));
            contact.put("name", e.getValue());
            contact.put("phones", values(context, e.getKey(),
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
                ContactsContract.CommonDataKinds.Phone.NUMBER));
            contact.put("emails", values(context, e.getKey(),
                ContactsContract.CommonDataKinds.Email.CONTENT_URI,
                ContactsContract.CommonDataKinds.Email.CONTACT_ID,
                ContactsContract.CommonDataKinds.Email.ADDRESS));
            out.add(contact);
        }
        return out;
    }

    private static List<String> values(Context context, long id, Uri table, String idColumn, String column) {
        List<String> out = new ArrayList<>();
        try (Cursor c = context.getContentResolver().query(
                table, new String[] {column}, idColumn + " = ?", new String[] {String.valueOf(id)}, null)) {
            while (c != null && c.moveToNext()) {
                String v = c.isNull(0) ? "" : c.getString(0);
                if (!v.isEmpty() && !out.contains(v)) out.add(v);
            }
        }
        return out;
    }

    /** Adds a contact to the phone (not to an online account); returns its id. */
    static String add(Context context, String name, String phone, String email) throws Exception {
        ArrayList<ContentProviderOperation> ops = new ArrayList<>();
        ops.add(ContentProviderOperation.newInsert(ContactsContract.RawContacts.CONTENT_URI)
            .withValue(ContactsContract.RawContacts.ACCOUNT_TYPE, null)
            .withValue(ContactsContract.RawContacts.ACCOUNT_NAME, null)
            .build());
        ops.add(ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
            .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
            .withValue(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE)
            .withValue(ContactsContract.CommonDataKinds.StructuredName.DISPLAY_NAME, name)
            .build());
        if (phone != null && !phone.isEmpty()) {
            ops.add(ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
                .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
                .withValue(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE)
                .withValue(ContactsContract.CommonDataKinds.Phone.NUMBER, phone)
                .withValue(ContactsContract.CommonDataKinds.Phone.TYPE, ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE)
                .build());
        }
        if (email != null && !email.isEmpty()) {
            ops.add(ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
                .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
                .withValue(ContactsContract.Data.MIMETYPE, ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE)
                .withValue(ContactsContract.CommonDataKinds.Email.ADDRESS, email)
                .withValue(ContactsContract.CommonDataKinds.Email.TYPE, ContactsContract.CommonDataKinds.Email.TYPE_OTHER)
                .build());
        }
        ContentProviderResult[] results = context.getContentResolver().applyBatch(ContactsContract.AUTHORITY, ops);
        long raw = ContentUris.parseId(results[0].uri);
        try (Cursor c = context.getContentResolver().query(
                ContactsContract.RawContacts.CONTENT_URI,
                new String[] {ContactsContract.RawContacts.CONTACT_ID},
                ContactsContract.RawContacts._ID + " = ?", new String[] {String.valueOf(raw)}, null)) {
            if (c != null && c.moveToFirst() && !c.isNull(0)) return String.valueOf(c.getLong(0));
        }
        return String.valueOf(raw);
    }
}
