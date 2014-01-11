/* Copyright 2014 Yorba Foundation
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

namespace California.Calendar {

/**
 * An immutable 1-based representation of a day of a month.
 *
 * Since no month is associated with this object, acceptable values are from {@link MIN} to
 * {@link MAX}, 1 to 31.
 */

public class DayOfMonth : SimpleValue {
    public const int MIN = 1;
    public const int MAX = 31;
    
    private static DayOfMonth[]? days = null;
    
    /**
     * Returns the day number as an informal (no leading zero) string.
     */
    public string informal_number { get; private set; }
    
    /**
     * Returns the day number as a formal (leading zero) string.
     */
    public string formal_number { get; private set; }
    
    private DayOfMonth(int value) {
        base (value, MIN, MAX);
        
        informal_number = "%d".printf(value);
        formal_number = "%02d".printf(value);
    }
    
    internal static void init() {
        days = new DayOfMonth[MAX - MIN + 1];
        for (int ctr = MIN; ctr <= MAX; ctr++)
            days[ctr - MIN] = new DayOfMonth(ctr);
    }
    
    internal static void terminate() {
        days = null;
    }
    
    /**
     * Returns a {@link DayOfMonth} for the supplied 1-based value.
     */
    public static DayOfMonth for(int value) throws CalendarError {
        int index = value - MIN;
        
        if (index < 0 || index >= days.length)
            throw new CalendarError.INVALID("Invalid day of month value %d", value);
        
        return days[index];
    }
    
    /**
     * Only use for internally-generated values, not externally-sourced ones (files, network,
     * user-input, etc.)
     */
    internal static DayOfMonth for_checked(int value) {
        try {
            return for(value);
        } catch (CalendarError calerr) {
            error("Invalid checked day of month %d: %s", value, calerr.message);
        }
    }
    
    internal static DayOfMonth from_gdate(GLib.Date gdate) {
        assert(gdate.valid());
        
        return for_checked(gdate.get_day());
    }
    
    /**
     * Returns the first day of the month for any month.
     */
    public static DayOfMonth first() {
        return for_checked(MIN);
    }
    
    internal inline DateDay to_date_day() {
        return (DateDay) value;
    }
    
    public override string to_string() {
        return formal_number;
    }
}

}

