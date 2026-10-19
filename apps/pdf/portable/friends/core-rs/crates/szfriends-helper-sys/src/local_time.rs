//! The computer's own time zone: its offset from UTC at an instant, with daylight saving as the system's rules say
//! (`localtime_r` on Unix, `SystemTimeToTzSpecificLocalTime` on Windows). The service words times for the person at
//! this computer ("Today at 14:40"), as the Mac helper does with the local time zone.

/// Seconds east of UTC at `unix_seconds` in this computer's time zone, or `None` when the system cannot say.
pub fn utc_offset_at(unix_seconds: i64) -> Option<i32> {
    imp::utc_offset_at(unix_seconds)
}

#[cfg(unix)]
mod imp {
    use std::sync::atomic::{AtomicI64, Ordering};

    pub fn utc_offset_at(unix_seconds: i64) -> Option<i32> {
        // A change of zone shows within a minute: tzset reads TZ and the zone file again, localtime_r alone may not.
        static LAST_TZSET: AtomicI64 = AtomicI64::new(i64::MIN);
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64);
        let last = LAST_TZSET.load(Ordering::Relaxed);
        if now.saturating_sub(last) >= 60
            && LAST_TZSET.compare_exchange(last, now, Ordering::Relaxed, Ordering::Relaxed).is_ok()
        {
            extern "C" {
                fn tzset();
            }
            // SAFETY: tzset takes no arguments and only refreshes the C library's zone state.
            unsafe { tzset() };
        }
        #[allow(clippy::useless_conversion)] // time_t is 32 bits on some Android ABIs
        let time: libc::time_t = unix_seconds.try_into().ok()?;
        let mut tm = std::mem::MaybeUninit::<libc::tm>::zeroed();
        // SAFETY: both pointers are valid for the call; localtime_r writes only into `tm` and is thread-safe.
        let filled = unsafe { libc::localtime_r(&time, tm.as_mut_ptr()) };
        if filled.is_null() {
            return None;
        }
        // SAFETY: localtime_r returned non-null, so it filled `tm`.
        let tm = unsafe { tm.assume_init() };
        i32::try_from(tm.tm_gmtoff).ok()
    }
}

#[cfg(windows)]
mod imp {
    use windows_sys::Win32::Foundation::{FILETIME, SYSTEMTIME};
    use windows_sys::Win32::System::Time::{
        FileTimeToSystemTime, SystemTimeToFileTime, SystemTimeToTzSpecificLocalTime,
    };

    /// 100-nanosecond intervals from 1601-01-01 to 1970-01-01.
    const UNIX_EPOCH_TICKS: i64 = 116_444_736_000_000_000;

    fn ticks(time: &FILETIME) -> i64 {
        ((u64::from(time.dwHighDateTime) << 32) | u64::from(time.dwLowDateTime)) as i64
    }

    pub fn utc_offset_at(unix_seconds: i64) -> Option<i32> {
        let utc_ticks = unix_seconds.checked_mul(10_000_000)?.checked_add(UNIX_EPOCH_TICKS)?;
        let utc = FILETIME { dwLowDateTime: utc_ticks as u32, dwHighDateTime: (utc_ticks >> 32) as u32 };
        let mut utc_system = std::mem::MaybeUninit::<SYSTEMTIME>::zeroed();
        let mut local_system = std::mem::MaybeUninit::<SYSTEMTIME>::zeroed();
        let mut local = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
        // SAFETY: every pointer is to a local of the right type, valid for the call; a null zone is the current one.
        let converted = unsafe {
            FileTimeToSystemTime(&utc, utc_system.as_mut_ptr()) != 0
                && SystemTimeToTzSpecificLocalTime(std::ptr::null(), utc_system.as_ptr(), local_system.as_mut_ptr())
                    != 0
                && SystemTimeToFileTime(local_system.as_ptr(), &mut local) != 0
        };
        if !converted {
            return None;
        }
        i32::try_from((ticks(&local) - utc_ticks) / 10_000_000).ok()
    }
}

#[cfg(not(any(unix, windows)))]
mod imp {
    pub fn utc_offset_at(_unix_seconds: i64) -> Option<i32> {
        None
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_offset_is_a_whole_zone_offset() {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
        let offset = super::utc_offset_at(now).expect("the system knows its zone");
        assert!((-14 * 3600..=14 * 3600).contains(&offset), "{offset}");
        assert_eq!(offset % 900, 0, "zones are whole quarter hours: {offset}");
    }
}
