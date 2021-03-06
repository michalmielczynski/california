/* Copyright 2014-2015 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

namespace California.View.Month {

/**
 * A Gtk.Grid of {@link Cell}s, each representing a particular {@link Calendar.Date}.
 */

private class Grid : Gtk.Grid {
    public const string PROP_MONTH_OF_YEAR = "month-of-year";
    public const string PROP_WINDOW = "window";
    
    // days of the week
    public const int COLS = Calendar.DayOfWeek.COUNT;
    
    // Delegate for walking only Cells in the Grid.  Return true to keep iterating.
    private delegate bool CellCallback(Cell cell);
    
    /**
     * {@link Month.Controller} that created and holds this {@link Grid}.
     */
    public weak Controller owner { get; private set; }
    
    /**
     * {@link MonthOfYear} this {@link Grid} represents.
     *
     * This is immutable; Grids are not designed to be re-used for other months.
     */
    public Calendar.MonthOfYear month_of_year { get; private set; }
    
    /**
     * The span of dates being displayed.
     */
    public Calendar.DateSpan window { get; private set; }
    
    /**
     * The name (id) of the {@link Grid}.
     *
     * This is used when the Grid is added to Gtk.Stack.
     */
    public string id { get { return month_of_year.full_name; } }
    
    /**
     * The number of rows (weeks) being displayed.
     */
    public int rows { get; private set; }
    
    private Gee.HashMap<Calendar.Date, Cell> date_to_cell = new Gee.HashMap<Calendar.Date, Cell>();
    private Backing.CalendarSubscriptionManager? subscriptions = null;
    private Toolkit.ButtonConnector cell_button_connector = new Toolkit.ButtonConnector();
    private Toolkit.MotionConnector cell_motion_connector = new Toolkit.MotionConnector();
    private Scheduled? scheduled_subscription_update = null;
    
    public Grid(Controller owner, Calendar.MonthOfYear month_of_year) {
        this.owner = owner;
        this.month_of_year = month_of_year;
        
        column_homogeneous = true;
        column_spacing = 0;
        row_homogeneous = true;
        row_spacing = 0;
        
        cell_button_connector.clicked.connect(on_cell_single_click);
        cell_button_connector.double_clicked.connect(on_cell_double_click);
        cell_motion_connector.entered.connect(on_cell_entered_exited);
        cell_motion_connector.exited.connect(on_cell_entered_exited);
        cell_motion_connector.motion.connect(on_cell_motion);
        cell_motion_connector.button_motion.connect(on_cell_button_motion);
        
        // create a WeekSpan for the first week of the month to the last week of the month
        Calendar.WeekSpan span = new Calendar.WeekSpan.from_span(month_of_year, Calendar.System.first_of_week);
        
        // prep the grid with a fixed number of rows (for visible weeks of the month) and columns
        // (for each day of the week) ... this needs to be done before attaching the Cells
        traverse<Calendar.Week>(span.as_list()).iterate(() => {
            insert_row(0);
        });
        
        for (int col = 0; col < COLS; col++)
            insert_column(0);
        
        // fill in weeks of days of the displayed month
        rows = 0;
        foreach (Calendar.Week week in span) {
            foreach (Calendar.Date date in week) {
                int col = date.day_of_week.ordinal(Calendar.System.first_of_week) - 1;
                
                Cell cell = new Cell(this, date, rows, col);
                cell.expand = true;
                cell_button_connector.connect_to(cell);
                cell_motion_connector.connect_to(cell);
                
                attach(cell, col, rows, 1, 1);
                
                // add to map for quick lookups
                date_to_cell.set(date, cell);
            }
            
            rows++;
        }
        
        // update the window being displayed
        window = span.to_date_span();
        
        // update subscriptions if this month is in view
        update_subscriptions();
        
        owner.notify[Controller.PROP_MONTH_OF_YEAR].connect(on_controller_month_of_year_changed);
    }
    
    ~Grid() {
        owner.notify[Controller.PROP_MONTH_OF_YEAR].disconnect(on_controller_month_of_year_changed);
    }
    
    /**
     * Returns the {@link Cell} for the specified {@link Calendar.Date}, if it is contained by this
     * {@link Grid}.
     */
    public Cell? get_cell_for_date(Calendar.Date date) {
        return date_to_cell.get(date);
    }
    
    private void foreach_cell(CellCallback callback) {
        foreach (unowned Gtk.Widget widget in get_children()) {
            // watch for Gtk.Labels across the top
            unowned Cell? cell = widget as Cell;
            if (cell != null && !callback(cell))
                return;
        }
    }
    
    private void foreach_cell_in_date_span(Calendar.DateSpan span, CellCallback callback) {
        foreach (Calendar.Date date in span) {
            Cell? cell = date_to_cell.get(date);
            if (cell != null && !callback(cell))
                return;
        }
    }
    
    // Must be in coordinates of the Gtk.Grid, not a Cell
    private Cell? translate_to_cell(int grid_x, int grid_y) {
        // TODO: A proper hit-detection algorithm would be better here
        Cell? hit = null;
        foreach_cell((cell) => {
            int cell_x, cell_y;
            if (!translate_coordinates(cell, grid_x, grid_y, out cell_x, out cell_y))
                return true;
            
            if (cell.is_hit(cell_x, cell_y))
                hit = cell;
            
            return hit == null;
        });
        
        return hit;
    }
    
    private void update_subscriptions() {
        // convert DateSpan window into an ExactTimeSpan, which is what the subscription wants
        Calendar.ExactTimeSpan time_window = new Calendar.ExactTimeSpan.from_span(window,
            Calendar.Timezone.local);
        
        if (subscriptions != null && subscriptions.window.equal_to(time_window))
            return;
        
        // create new subscription manager, subscribe to its signals, and let them drive
        subscriptions = new Backing.CalendarSubscriptionManager(time_window);
        subscriptions.calendar_added.connect(on_calendar_added);
        subscriptions.calendar_removed.connect(on_calendar_removed);
        subscriptions.instance_added.connect(on_instance_added_or_altered);
        subscriptions.instance_altered.connect(on_instance_added_or_altered);
        subscriptions.instance_removed.connect(on_instance_removed);
        
        // only start if this month is being displayed, otherwise will be started when owner's
        // month of year changes to this one or a timeout (to prevent only subscribing
        // when scrolled into view)
        if (owner.month_of_year.equal_to(month_of_year)) {
            subscriptions.start_async.begin();
        } else {
            // use distance from currently displayed month as a way to space out subscription
            // starts, which are a little taxing ... assume future months are more likely to be
            // moved to than past months, hence earlier months get the +1 dinged against them
            int diff = owner.month_of_year.difference(month_of_year);
            if (diff < 0)
                diff = diff.abs() + 1;
            
            scheduled_subscription_update = new Scheduled.once_after_msec(300 + (diff * 100), () => {
                subscriptions.start_async.begin();
            });
        }
    }
    
    private void on_controller_month_of_year_changed() {
        // if this Grid is being displayed, immediately activate subscriptions
        if (!owner.month_of_year.equal_to(month_of_year))
            return;
        
        if (subscriptions == null)
            update_subscriptions();
        else if (!subscriptions.is_started)
            subscriptions.start_async.begin();
    }
    
    private void on_calendar_added(Backing.CalendarSource calendar) {
        calendar.notify[Backing.Source.PROP_VISIBLE].connect(on_calendar_display_changed);
        calendar.notify[Backing.Source.PROP_COLOR].connect(on_calendar_display_changed);
    }
    
    private void on_calendar_removed(Backing.CalendarSource calendar) {
        calendar.notify[Backing.Source.PROP_VISIBLE].disconnect(on_calendar_display_changed);
        calendar.notify[Backing.Source.PROP_COLOR].disconnect(on_calendar_display_changed);
    }
    
    private void on_calendar_display_changed(Object o, ParamSpec pspec) {
        Backing.CalendarSource calendar = (Backing.CalendarSource) o;
        
        foreach_cell((cell) => {
            cell.notify_calendar_display_changed(calendar);
            
            return true;
        });
    }
    
    private void on_instance_added_or_altered(Component.Instance instance) {
        Component.Event? event = instance as Component.Event;
        if (event == null)
            return;
        
        // add event to every date it represents ... in the "instance-altered" case, if the event's
        // date changes it doesn't need to be removed here (Month.Call catches the change and
        // removes it itself) but it does need to be added to the new date(s) it covers
        foreach_cell_in_date_span(event.get_event_date_span(Calendar.Timezone.local), (cell) => {
            cell.add_event(event);
            
            return true;
        });
    }
    
    private void on_instance_removed(Component.Instance instance) {
        Component.Event? event = instance as Component.Event;
        if (event == null)
            return;
        
        // remove event from every date it represents
        foreach_cell_in_date_span(event.get_event_date_span(Calendar.Timezone.local), (cell) => {
            cell.remove_event(event);
            
            return true;
        });
    }
    
    public void unselect_all() {
        foreach_cell((cell) => {
            cell.selected = false;
            
            return true;
        });
    }
    
    // A button event returns all coordinates in the coordinate system of the pressed widget ...
    // this determines which widget the button was released over and returns the point of release
    // in that widget's coordinate system
    private Cell? get_released_cell(Toolkit.ButtonEvent details, ref Gdk.Point release_cell_point) {
        // The GDK coordinates are relative to the pressed Cell, so translate to the GtkGrid
        int grid_x, grid_y;
        if (!details.widget.translate_coordinates(this, details.release_point.x, details.release_point.y,
            out grid_x, out grid_y)) {
            return null;
        }
        
        // Now translate the released coordinates back to the right Cell, if it is a Cell
        Cell? release_cell = translate_to_cell(grid_x, grid_y);
        if (release_cell == null)
            return null;
        
        // translate release point coordinates into the coordinates of the released cell
        if (!details.widget.translate_coordinates(release_cell, details.release_point.x, details.release_point.y,
            out release_cell_point.x, out release_cell_point.y)) {
            return null;
        }
        
        return release_cell;
    }
    
    private bool on_cell_single_click(Toolkit.ButtonEvent details) {
        // only want primary button clicks
        if (details.button != Toolkit.Button.PRIMARY)
            return Toolkit.PROPAGATE;
        
        // get the Cell the button was released on (if it's a Cell at all)
        Gdk.Point release_cell_point = Gdk.Point();
        Cell? release_cell = get_released_cell(details, ref release_cell_point);
        if (release_cell == null) {
            // reset state and exit
            unselect_all();
            
            return Toolkit.STOP;
        }
        
        bool stop_propagation = Toolkit.PROPAGATE;
        
        Cell press_cell = (Cell) details.widget;
        
        Toolkit.set_toplevel_cursor(this, null);
        
        // if pressed and released on the same cell, display the event at the released location
        if (press_cell == release_cell) {
            Component.Event? event = release_cell.get_event_at(details.release_point);
            if (event != null) {
                owner.request_display_event(event, release_cell, release_cell_point);
                stop_propagation = Toolkit.STOP;
            }
        } else {
            // create multi-day event
            owner.request_create_all_day_event(new Calendar.DateSpan(press_cell.date, release_cell.date),
                release_cell, release_cell_point);
            stop_propagation = Toolkit.STOP;
        }
        
        return stop_propagation;
    }
    
    private bool on_cell_double_click(Toolkit.ButtonEvent details) {
        // only interested in primary button clicks
        if (details.button != Toolkit.Button.PRIMARY)
            return Toolkit.PROPAGATE;
        
        // get the Cell the button was released on (if it's a Cell at all)
        Gdk.Point release_cell_point = Gdk.Point();
        Cell? release_cell = get_released_cell(details, ref release_cell_point);
        if (release_cell == null) {
            // reset state and exit
            unselect_all();
            
            return Toolkit.PROPAGATE;
        }
        
        Cell press_cell = (Cell) details.widget;
        
        // only interested in double-clicking on the same cell
        if (press_cell != release_cell)
            return Toolkit.PROPAGATE;
        
        // if an existing event is double-clicked, open for editing, otherwise create new event
        Component.Event? event = release_cell.get_event_at(release_cell_point);
        if (event != null) {
            owner.request_edit_event(event, release_cell, release_cell_point);
        } else {
            owner.request_create_all_day_event(new Calendar.DateSpan(press_cell.date, release_cell.date),
                release_cell, release_cell_point);
        }
        
        return Toolkit.STOP;
    }
    
    private void on_cell_entered_exited(Toolkit.MotionEvent details) {
        // when entering or leaving cell, reset the cursor
        Toolkit.set_toplevel_cursor(details.widget, null);
    }
    
    private void on_cell_motion(Toolkit.MotionEvent details) {
        Cell cell = (Cell) details.widget;
        
        // if hovering over an event, show the "hyperlink" cursor
        Gdk.CursorType? cursor_type = null;
        if (cell.get_event_at(details.point) != null)
            cursor_type = Gdk.CursorType.HAND1;
        
        Toolkit.set_toplevel_cursor(cell, cursor_type);
    }
    
    private void on_cell_button_motion(Toolkit.MotionEvent event) {
        if (!event.is_button_pressed(Toolkit.Button.PRIMARY))
            return;
        
        // Because using button 1 motion mask, widget is always the original cell the button-pressed
        // event originated at
        Cell press_cell = (Cell) event.widget;
        
        // turn Cell coordinates into GtkGrid coordinates
        int grid_x, grid_y;
        if (!press_cell.translate_coordinates(this, event.point.x, event.point.y, out grid_x, out grid_y))
            return;
        
        // get the cell the pointer is currently over ... if not found or the same as the original,
        // do nothing
        Cell? hover_cell = translate_to_cell(grid_x, grid_y);
        if (hover_cell == null || hover_cell == press_cell)
            return;
        
        // mark two cells and all in-between as selected, being sure to mark any previous selected
        // as unselected
        Calendar.DateSpan span = new Calendar.DateSpan(press_cell.date, hover_cell.date);
        foreach_cell((cell) => {
            cell.selected = cell.date in span;
            
            return true;
        });
    }
}

}

