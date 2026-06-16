#!/usr/bin/env bash
# Benchmark HTML-to-PNG converters for email rendering
# Usage: nix-shell -p weasyprint chromium --run ./bench/render_benchmark.sh

set -euo pipefail

OUTDIR=$(mktemp -d --suffix="-himalaya-bench")
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Generate test emails of varying complexity
cat > "$TMPDIR/simple.html" << 'HTML'
<html><body style="font-family: Arial; padding: 20px;">
<h1>Simple Email</h1>
<p>Hello, this is a <strong>plain</strong> email with minimal formatting.</p>
</body></html>
HTML

cat > "$TMPDIR/table.html" << 'HTML'
<html><body style="font-family: Arial; padding: 20px;">
<h2>Order Confirmation</h2>
<table border="1" cellpadding="8" style="border-collapse: collapse; width: 100%;">
<tr style="background: #f0f0f0;"><th>Item</th><th>Qty</th><th>Price</th></tr>
<tr><td>Widget A</td><td>2</td><td>$19.99</td></tr>
<tr><td>Widget B</td><td>1</td><td>$49.99</td></tr>
<tr><td>Widget C</td><td>5</td><td>$9.99</td></tr>
<tr style="font-weight: bold;"><td colspan="2">Total</td><td>$139.92</td></tr>
</table>
<p style="color: #666; font-size: 12px;">Thank you for your purchase.</p>
</body></html>
HTML

cat > "$TMPDIR/complex.html" << 'HTML'
<html><head><style>
body { margin: 0; font-family: -apple-system, Arial, sans-serif; background: #f5f5f5; }
.wrapper { max-width: 600px; margin: 0 auto; background: #fff; }
.header { background: #1a73e8; color: #fff; padding: 24px; text-align: center; }
.content { padding: 24px; }
.card { border: 1px solid #ddd; border-radius: 8px; padding: 16px; margin: 12px 0; }
.card h3 { margin-top: 0; color: #333; }
.footer { background: #f0f0f0; padding: 16px; text-align: center; font-size: 12px; color: #999; }
.btn { display: inline-block; background: #1a73e8; color: #fff; padding: 12px 24px;
       text-decoration: none; border-radius: 4px; margin: 8px 0; }
</style></head><body>
<div class="wrapper">
  <div class="header"><h1>Newsletter</h1><p>February 2026</p></div>
  <div class="content">
    <p>Hi there,</p>
    <div class="card">
      <h3>Feature Update</h3>
      <p>We have released a major update with new rendering capabilities and performance improvements.</p>
      <a class="btn" href="#">Learn More</a>
    </div>
    <div class="card">
      <h3>Upcoming Events</h3>
      <table style="width: 100%; border-collapse: collapse;">
        <tr><td style="padding: 8px; border-bottom: 1px solid #eee;">Conference 2026</td><td style="padding: 8px; border-bottom: 1px solid #eee;">Mar 15</td></tr>
        <tr><td style="padding: 8px; border-bottom: 1px solid #eee;">Workshop</td><td style="padding: 8px; border-bottom: 1px solid #eee;">Apr 2</td></tr>
        <tr><td style="padding: 8px;">Meetup</td><td style="padding: 8px;">Apr 20</td></tr>
      </table>
    </div>
    <p>Best regards,<br>The Team</p>
  </div>
  <div class="footer">You received this because you subscribed. <a href="#">Unsubscribe</a></div>
</div>
</body></html>
HTML

run_bench() {
  local name="$1" cmd="$2" input="$3" output="$4" runs="${5:-5}"
  local times=()

  for i in $(seq 1 "$runs"); do
    start=$(date +%s%N)
    eval "$cmd" > /dev/null 2>&1
    end=$(date +%s%N)
    ms=$(( (end - start) / 1000000 ))
    times+=("$ms")
  done

  # compute min/max/avg
  local sum=0 min=${times[0]} max=${times[0]}
  for t in "${times[@]}"; do
    sum=$((sum + t))
    (( t < min )) && min=$t
    (( t > max )) && max=$t
  done
  local avg=$((sum / ${#times[@]}))
  local size
  size=$(du -h "$output" 2>/dev/null | cut -f1)

  printf "  %-12s  min=%4dms  avg=%4dms  max=%4dms  size=%s\n" "$name" "$min" "$avg" "$max" "$size"
}

CHROMIUM=$(command -v chromium 2>/dev/null || command -v chromium-browser 2>/dev/null || command -v google-chrome-stable 2>/dev/null || true)
WEASYPRINT=$(command -v weasyprint 2>/dev/null || true)

echo "=== HTML-to-PNG Converter Benchmark (5 runs each) ==="
echo ""

for label in simple table complex; do
  input="$TMPDIR/${label}.html"
  echo "[$label.html]"

  if [ -n "$CHROMIUM" ]; then
    out="$OUTDIR/${label}_chromium.png"
    run_bench "chromium" \
      "$CHROMIUM --headless --disable-gpu --no-sandbox --screenshot='$out' --window-size=800,600 'file://$input'" \
      "$input" "$out"
  else
    echo "  chromium      (not found, skipped)"
  fi

  if [ -n "$WEASYPRINT" ]; then
    out="$OUTDIR/${label}_weasyprint.png"
    run_bench "weasyprint" \
      "weasyprint '$input' '$out'" \
      "$input" "$out"
  else
    echo "  weasyprint    (not found, skipped)"
  fi

  # Also keep the source HTML for reference
  cp "$input" "$OUTDIR/"

  echo ""
done

echo "=== Done ==="
echo "Output PNGs persisted at: $OUTDIR"
ls -lh "$OUTDIR"/*.png
