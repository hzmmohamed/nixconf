import { Action, ActionPanel, Detail, Icon } from "@vicinae/api";
import { useEffect, useState } from "react";
import { WallpaperDetail } from "./components";
import { currentWallpaper, type Wallpaper, wallpaperFromSidecar } from "./lib";

export default function CurrentWallpaper() {
	const [wallpaper, setWallpaper] = useState<Wallpaper | null>(null);
	const [error, setError] = useState<string | null>(null);

	useEffect(() => {
		currentWallpaper()
			.then(({ file, sidecar }) => {
				if (!file) throw new Error("set-wallpaper --info did not report a file");
				const hasSidecar = Object.keys(sidecar).some((k) => k !== "file");
				setWallpaper(wallpaperFromSidecar(file, hasSidecar ? sidecar : null));
			})
			.catch((e) => setError(e instanceof Error ? e.message : String(e)));
	}, []);

	if (error)
		return (
			<Detail
				markdown={`# Could not read the current wallpaper\n\n\`set-wallpaper --info\` failed:\n\n\`\`\`\n${error}\n\`\`\``}
				actions={
					<ActionPanel>
						<Action.CopyToClipboard title="Copy Error" icon={Icon.CopyClipboard} content={error} />
					</ActionPanel>
				}
			/>
		);
	if (!wallpaper) return <Detail markdown="Loading current wallpaper…" />;
	return <WallpaperDetail wallpaper={wallpaper} />;
}
