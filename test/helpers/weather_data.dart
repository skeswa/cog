typedef WeatherData = ({
  double cloudCoverPercentage,
  double percentChanceOfRain,
  double tempInCelsius,
});

Future<WeatherData> fetchWeatherData({
  required DateTime timeOfDay,
  required int zipCode,
}) async {
  final secondsSinceEpoch = timeOfDay.millisecondsSinceEpoch ~/ 1000;

  final secondsIntoTheDay = secondsSinceEpoch % (60 * 60 * 24);

  final cloudCoverPercentage =
      ((zipCode * 113 + secondsIntoTheDay * 71) % 1000) / 2000.0;
  final percentChanceOfRain =
      ((zipCode * 211 + secondsIntoTheDay * 53) % 1000) / 1600.0;
  final tempInCelsius =
      ((((zipCode * 23 + secondsIntoTheDay * 53) % 1000) / 1000.0) * 26) + 7;

  final requestDurationInMilliseconds =
      ((((zipCode * 31 + secondsIntoTheDay * 7) % 1000) / 1000.0) * 2000)
              .round() +
          150;

  await Future.delayed(Duration(milliseconds: requestDurationInMilliseconds));

  return (
    cloudCoverPercentage: cloudCoverPercentage,
    percentChanceOfRain: percentChanceOfRain,
    tempInCelsius: tempInCelsius,
  );
}
