// This file is part of GNOME Boxes. License: LGPLv2+

[DBus (name = "org.gnome.Shell.SearchProvider")]
private class Boxes.SearchProvider: Object {
    private SearchProviderApp app;
    private bool loading;
    public bool loaded { get; set; }
    private HashTable<string, DisplayProperties> boxes;
    private uint next_id;

    public SearchProvider (SearchProviderApp app) {
        this.app = app;
        boxes = new HashTable<string, DisplayProperties> (str_hash, str_equal);
    }

    private void add_box (DisplayProperties box) {
        var id = next_id++.to_string ();
        box.set_data ("search-id", id);

        boxes.insert (id, box);
    }

    private async void load () {
        // avoid reentering load () from a different request
        while (!loaded && loading) {
            var wait = notify["loaded"].connect (() => {
                load.callback ();
            });

            yield;

            disconnect (wait);
            if (loaded)
                return;
        }

        loading = true;
        var dir = File.new_for_path (get_user_pkgconfig_source ());
        yield foreach_filename_from_dir (dir, (filename) => {
            var source = new CollectionSource.with_file (filename);
            if (!source.enabled)
                return false;

            foreach (var group in source.get_groups ("display")) {
                var config = new DisplayConfig.with_group (source, group);
                var box = new DisplayProperties.with_config (config);
                add_box (box);
            }

            return false;
        });

        loaded = true;
        loading = false;
    }

    private static int compare_boxes (DisplayProperties a, DisplayProperties b) {
        // sort first by last time used
        if (a.access_last_time > b.access_last_time)
            return -1;

        var a_name = a.config.last_seen_name;
        var b_name = b.config.last_seen_name;

        // then by name
        if (is_set (a_name) && is_set (b_name))
            return a_name.collate (b_name);

        // Sort empty names last
        if (is_set (a_name))
            return -1;
        if (is_set (b_name))
            return -1;

        return 0;
    }

    private async string[] search (string[] terms) {
        app.hold ();
        string[] normalized_terms = canonicalize_for_search (string.joinv(" ", terms)).split(" ");
        var matches = new GenericArray<DisplayProperties> ();

        debug ("search (%s)", string.joinv (", ", terms));
        if (!loaded)
            yield load ();

        foreach (var box in boxes.get_values ()) {
            if (box.contains_strings (normalized_terms))
                matches.add (box);
        }

        matches.sort((CompareFunc<DisplayProperties>) compare_boxes);
        var results = new string[matches.length];
        for (int i = 0; i < matches.length; i++)
            results[i] = matches[i].get_data ("search-id");

        app.release ();
        return results;
    }

    public async string[] GetInitialResultSet (string[] terms) {
        return yield search (terms);
    }

    public async string[] GetSubsearchResultSet (string[] previous_results,
                                           string[] new_terms) {
        return yield search (new_terms);
    }

    public async HashTable<string, Variant>[] GetResultMetas (string[] ids) {
        var metas = new HashTable<string, Variant>[ids.length];
        app.hold ();

        debug ("GetResultMetas (%s)", string.joinv (", ", ids));
        uint n = 0;
        foreach (var id in ids) {
            var box = boxes.lookup (id);
            if (box == null)
                continue;

            var meta = new HashTable<string, Variant> (str_hash, str_equal);
            metas[n] = meta;
            n++;

            meta.insert ("id", new Variant.string (id));
            meta.insert ("name", new Variant.string (box.config.last_seen_name));

            var file = File.new_for_path (Boxes.get_screenshot_filename (box.config.uuid));
            FileInfo? info = null;
            try {
                info = yield file.query_info_async (FileAttribute.STANDARD_TYPE, FileQueryInfoFlags.NONE);
            } catch (GLib.Error error) { }

            if (info != null) {
                var icon = new FileIcon (file);
                meta.insert ("gicon", new Variant.string (icon.to_string ()));
            } else {
                meta.insert ("gicon", new Variant.string (new ThemedIcon ("gnome-boxes").to_string ()));
            }
        }

        app.release ();
        return metas[0:n];
    }

    public void ActivateResult (string search_id) {
        app.hold ();

        debug ("ActivateResult (%s)", search_id);

        app.release ();
    }
}

public class Boxes.SearchProviderApp: GLib.Application {
    public SearchProviderApp () {
        Object (application_id: "org.gnome.Boxes.SearchProvider",
                flags: ApplicationFlags.IS_SERVICE,
                inactivity_timeout: 10000);
    }

    public override bool dbus_register (GLib.DBusConnection connection, string object_path) {
        try {
            connection.register_object (object_path, new SearchProvider (this));
        } catch (IOError error) {
            stderr.printf ("Could not register service: %s", error.message);
            quit ();
        }
        return true;
    }

    public override void startup () {
        if (Environment.get_variable ("BOXES_SEARCH_PROVIDER_PERSIST") != null)
            hold ();
        base.startup ();
    }
}

int main () {
    return new Boxes.SearchProviderApp ().run ();
}
