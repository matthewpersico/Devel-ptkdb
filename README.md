# Devel-ptkdb

Placeholder for the long saga of how we got here.

## Developer notes

### Icons

If you change the icon source png, you need to recreate the icons:

```
for i in 16 32 48 64 128; do convert ptkdb.png -resize ${i}x$i ptkdb-$i.png; done
```
