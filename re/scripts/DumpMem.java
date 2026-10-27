// Dump bytes at address:length and annotate pointer-looking qwords.
// @category SAA
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;

public class DumpMem extends GhidraScript {
    public void run() throws Exception {
        Memory mem = currentProgram.getMemory();
        for (String a : getScriptArgs()) {
            String[] p = a.split(":");
            Address addr = toAddr(Long.parseLong(p[0], 16));
            int len = Integer.parseInt(p[1], 16);
            byte[] b = new byte[len];
            try { mem.getBytes(addr, b); } catch (Exception e) {
                println("ERR " + a + " " + e); continue;
            }
            println("== " + addr + " len 0x" + Integer.toHexString(len) + " ==");
            for (int i = 0; i < len; i += 16) {
                StringBuilder hex = new StringBuilder();
                StringBuilder asc = new StringBuilder();
                for (int j = 0; j < 16 && i + j < len; j++) {
                    hex.append(String.format("%02x ", b[i + j]));
                    int c = b[i + j] & 0xff;
                    asc.append(c >= 32 && c < 127 ? (char) c : '.');
                }
                // pointer annotation for the first and third qwords
                StringBuilder notes = new StringBuilder();
                for (int k = 0; k + 8 <= 16 && i + k + 8 <= len; k += 8) {
                    long v = 0;
                    for (int n = 7; n >= 0; n--) v = (v << 8) | (b[i + k + n] & 0xffL);
                    if (v >= 0x10000 && v < 0x60000) {
                        Function f = getFunctionContaining(toAddr(v));
                        notes.append(String.format(" [%02x]->0x%x %s", k, v,
                                f != null ? f.getName() : ""));
                    }
                }
                println(String.format("%08x  %-48s %s%s", addr.getOffset() + i,
                        hex.toString(), asc.toString(), notes.toString()));
            }
        }
    }
}
