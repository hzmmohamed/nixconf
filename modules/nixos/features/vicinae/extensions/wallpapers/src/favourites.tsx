import { Grid, Icon } from "@vicinae/api";
import { useCallback, useEffect, useState } from "react";
import { WallpaperItem } from "./components";
import { FAVOURITES_DIR, listFavourites, type Wallpaper } from "./lib";

export default function Favourites() {
	const [items, setItems] = useState<Wallpaper[]>([]);
	const [isLoading, setIsLoading] = useState(true);

	const reload = useCallback(() => {
		setIsLoading(true);
		listFavourites()
			.then(setItems)
			.finally(() => setIsLoading(false));
	}, []);

	useEffect(reload, [reload]);

	return (
		<Grid columns={4} aspectRatio="16/9" fit={Grid.Fit.Fill} isLoading={isLoading} searchBarPlaceholder="Filter favourites…">
			{!isLoading && items.length === 0 ? (
				<Grid.EmptyView icon={Icon.Star} title="No favourites yet" description={`Use "Add to Favourites" in the other wallpaper commands (${FAVOURITES_DIR})`} />
			) : (
				<Grid.Section title={`${items.length} favourites`}>
					{items.map((w) => (
						<WallpaperItem key={w.id} wallpaper={w} isFavourite onChanged={reload} />
					))}
				</Grid.Section>
			)}
		</Grid>
	);
}
