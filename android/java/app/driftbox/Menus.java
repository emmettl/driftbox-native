package app.driftbox;

import android.view.HapticFeedbackConstants;
import android.view.Menu;
import android.view.MenuItem;
import android.view.View;
import android.widget.PopupMenu;
import java.util.ArrayList;
import java.util.List;

/**
 * A long press's menu, shown as Android's own: a {@link PopupMenu} at the finger, a buzz as it
 * opens. Swift hands it over as lines of text (Swift's {@code MenuLines}); a submenu opens as another
 * menu in the same place when it is tapped, the way phones show one, since a popup menu holds only
 * one level of submenu and Driftbox's go two deep. Whatever is chosen goes back to Swift.
 */
final class Menus {
  private Menus() {}

  /** An item: a command, a submenu, or a separator. */
  private static final class Item {
    char kind;
    String id;
    String title;
    boolean enabled = true;
    boolean checked;
    final List<Item> children = new ArrayList<>();
  }

  /**
   * Show the menu {@code lines} describe, from {@code anchor}, a view the size of a finger's point
   * that is moved to where it was pressed first; {@code density} is pixels to a point.
   */
  static void show(View anchor, String lines, float density) {
    String[] rows = lines.split("\n");
    String[] head = rows[0].split("\t", -1);
    anchor.setX(Float.parseFloat(head[0]) * density);
    anchor.setY(Float.parseFloat(head[1]) * density);
    Item root = new Item();
    root.title = head[2];
    // The open items at each depth, the menu itself below them all.
    List<Item> open = new ArrayList<>();
    open.add(root);
    for (int at = 1; at < rows.length; at++) {
      String[] field = rows[at].split("\t", -1);
      int depth = Integer.parseInt(field[0]);
      Item item = new Item();
      item.kind = field[1].charAt(0);
      if (item.kind != '-') {
        item.id = field[2];
        item.title = field[3];
      }
      if (item.kind == 'c') {
        item.enabled = field[4].equals("1");
        item.checked = field[5].equals("1");
      }
      while (open.size() > depth + 1) open.remove(open.size() - 1);
      open.get(open.size() - 1).children.add(item);
      if (item.kind == 's') open.add(item);
    }
    anchor.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
    // Laid out first, so the popup opens where the anchor has moved to.
    anchor.post(() -> popUp(anchor, root));
  }

  private static void popUp(View anchor, Item menu) {
    PopupMenu popup = new PopupMenu(anchor.getContext(), anchor);
    Menu items = popup.getMenu();
    items.setGroupDividerEnabled(true);
    List<Item> byId = new ArrayList<>();
    // What it is the menu of, which a popup has no title to say: its first line, greyed.
    items.add(0, byId.size(), Menu.NONE, menu.title).setEnabled(false);
    byId.add(menu);
    int group = 1;
    for (Item item : menu.children) {
      if (item.kind == '-') {
        // A new group: Android draws a line between groups.
        group += 1;
        continue;
      }
      MenuItem added = items.add(group, byId.size(), Menu.NONE, item.kind == 's' ? item.title + "  ›" : item.title);
      added.setEnabled(item.enabled);
      if (item.checked) added.setCheckable(true).setChecked(true);
      byId.add(item);
    }
    popup.setOnMenuItemClickListener(
        chosen -> {
          Item item = byId.get(chosen.getItemId());
          if (item.kind == 's') {
            popUp(anchor, item);
          } else {
            Native.menuChosen(item.id);
          }
          return true;
        });
    popup.show();
  }
}
