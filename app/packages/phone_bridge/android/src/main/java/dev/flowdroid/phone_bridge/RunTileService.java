package dev.flowdroid.phone_bridge;

import android.app.PendingIntent;
import android.content.Intent;
import android.os.Build;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

import org.json.JSONException;
import org.json.JSONObject;

/** The "Run FlowDroid" Quick Settings tile: runs workflows with a Quick Tile Trigger. */
public class RunTileService extends TileService {
    @Override
    public void onStartListening() {
        Tile tile = getQsTile();
        if (tile == null) return;
        tile.setState(Tile.STATE_INACTIVE);
        tile.updateTile();
    }

    @Override
    public void onClick() {
        try {
            Events.write(this, new JSONObject().put("type", "tile"));
        } catch (JSONException ignored) {
            // Constant strings always fit in JSON.
        }
        if (Events.dartAlive(this)) return;
        // Nothing is running to pick the event up: open FlowDroid, which then runs it.
        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (launch == null) return;
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE));
        } else {
            startActivityAndCollapse(launch);
        }
    }
}
