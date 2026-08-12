package com.oscilla.tcexec;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStreamReader;
import java.util.Map;

/**
 * Proves the REAL rebuilt bionic AVR toolchain binaries execve() from a genuine
 * untrusted_app process (release manifest, debuggable=0), packaged as lib*.so in
 * nativeLibraryDir. This is the Phase-B exec gate: the spike only proved a glibc
 * probe from /data/local/tmp, never the shipped compiler binaries from an app.
 *
 * Children are dynamically linked (PT_INTERP=/system/bin/linker64) and cc1plus
 * DT_NEEDEDs libc++_shared.so, so we set LD_LIBRARY_PATH=<nativeLibraryDir>,
 * exactly as CompilerService will.
 */
public class ExecTestTC extends Activity {
    static final String TAG = "OSCILLA_TCEXEC";

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        try { runAll(); } catch (Throwable t) { Log.e(TAG, "harness failed", t); }
        Log.i(TAG, "=== DONE ===");
        finish();
    }

    void runAll() throws Exception {
        String ctx = readFile("/proc/self/attr/current").trim();
        String libDir = getApplicationInfo().nativeLibraryDir;
        Log.i(TAG, "selinux_context = " + ctx);
        Log.i(TAG, "targetSdk       = " + getApplicationInfo().targetSdkVersion);
        Log.i(TAG, "nativeLibraryDir= " + libDir);
        Log.i(TAG, "listing         = " + java.util.Arrays.toString(new File(libDir).list()));

        // A: avr-ld from nativeLibraryDir (apk_data_file) — the read-only exec dir
        exec("A libavrld.so --version", libDir,
             new String[]{ libDir + "/libavrld.so", "--version" });

        // B: cc1plus from nativeLibraryDir — needs libc++_shared.so via LD_LIBRARY_PATH
        exec("B libcc1plus.so --version", libDir,
             new String[]{ libDir + "/libcc1plus.so", "--version" });

        // C: avr-as from nativeLibraryDir
        exec("C libavras.so --version", libDir,
             new String[]{ libDir + "/libavras.so", "--version" });

        // D: the PRODUCTION symlink-farm path — a bare-named symlink in filesDir
        // (app_data_file) pointing at the real lib*.so in nativeLibraryDir. GCC
        // execs children by bare name ("cc1plus","as","ld"); this is how the farm
        // gives them those names over a read-only, lib*.so-only dir.
        File ld = new File(getFilesDir(), "avr-ld");
        ld.delete();
        android.system.Os.symlink(libDir + "/libavrld.so", ld.getAbsolutePath());
        exec("D filesDir/avr-ld(symlink)->libavrld.so --version", libDir,
             new String[]{ ld.getAbsolutePath(), "--version" });
    }

    void exec(String label, String libDir, String[] argv) {
        // Tolerate a partial payload: when only part of the toolchain is built
        // yet, report SKIP rather than a misleading DENIED.
        File bin = new File(argv[0]);
        if (!bin.exists()) { Log.i(TAG, "RESULT " + label + " => SKIP (not packaged)"); return; }
        try {
            ProcessBuilder pb = new ProcessBuilder(argv);
            pb.redirectErrorStream(true);
            Map<String,String> env = pb.environment();
            env.put("LD_LIBRARY_PATH", libDir);
            Process p = pb.start();
            StringBuilder sb = new StringBuilder();
            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
            String line; int n = 0;
            while ((line = r.readLine()) != null && n++ < 3) sb.append(line).append(" | ");
            int rc = p.waitFor();
            Log.i(TAG, "RESULT " + label + " => EXEC_OK rc=" + rc + " out=" + sb);
        } catch (Exception ex) {
            Log.i(TAG, "RESULT " + label + " => DENIED "
                    + ex.getClass().getSimpleName() + ": " + ex.getMessage());
        }
    }

    static String readFile(String p) {
        try (FileInputStream in = new FileInputStream(p)) {
            byte[] buf = new byte[4096]; int n = in.read(buf);
            return n > 0 ? new String(buf, 0, n) : "";
        } catch (Exception e) { return "?"; }
    }
}
