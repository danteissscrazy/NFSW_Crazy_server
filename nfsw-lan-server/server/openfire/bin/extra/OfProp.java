import java.sql.*;

public class OfProp {
    public static void main(String[] a) throws Exception {
        String url = "jdbc:hsqldb:" + a[0] + "/openfire";
        Class.forName("org.hsqldb.jdbcDriver");
        try (Connection c = DriverManager.getConnection(url, "sa", "")) {
            for (int i = 1; i + 1 < a.length; i += 2) {
                String k = a[i], v = a[i + 1];
                try (PreparedStatement d = c.prepareStatement("DELETE FROM ofProperty WHERE name=?")) {
                    d.setString(1, k); d.executeUpdate();
                }
                try (PreparedStatement p = c.prepareStatement("INSERT INTO ofProperty (name, propValue, encrypted) VALUES (?,?,0)")) {
                    p.setString(1, k); p.setString(2, v); p.executeUpdate();
                }
                System.out.println("SET " + k + " = " + v);
            }
            try (Statement s = c.createStatement()) { s.execute("SHUTDOWN"); }
        }
        System.out.println("DONE");
    }
}
