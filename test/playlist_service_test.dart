import 'package:flutter_test/flutter_test.dart';
import 'package:sr_player/services/playlist_service.dart';

void main() {
  test('集数识别：中文第xx集/话', () {
    expect(PlaylistService.episodeNumberOf('龙珠第055集.mp4'), 55);
    expect(PlaylistService.episodeNumberOf('海贼王第1012话.mkv'), 1012);
  });

  test('集数识别：EP/Exx 与 SxxEyy', () {
    expect(PlaylistService.episodeNumberOf('[Sub] Name EP037 [1080p].mkv'), 37);
    expect(PlaylistService.episodeNumberOf('[Sub] Name E37 [720p].mkv'), 37);
    expect(PlaylistService.episodeNumberOf('Show S01E05.mp4'), 5);
  });

  test('集数识别：分隔符数字与结尾数字', () {
    expect(PlaylistService.episodeNumberOf('Show - 05 [720p].mkv'), 5);
    expect(PlaylistService.episodeNumberOf('Show - 12.mkv'), 12);
    expect(PlaylistService.episodeNumberOf('05.mkv'), 5);
  });

  test('集数识别：分辨率等数字不误判', () {
    expect(PlaylistService.episodeNumberOf('[1080p] Name.mp4'), isNull);
    expect(PlaylistService.episodeNumberOf('2160p.Name.mkv'), isNull);
    expect(PlaylistService.episodeNumberOf('noext'), isNull);
    expect(PlaylistService.episodeNumberOf('名字没有数字.mkv'), isNull);
  });

  test('自然排序：数字段按数值比较', () {
    expect(PlaylistService.naturalCompare('第2集', '第10集'), isNegative);
    expect(PlaylistService.naturalCompare('EP9', 'EP11'), isNegative);
    expect(PlaylistService.naturalCompare('a2b', 'a2b'), 0);
    expect(PlaylistService.naturalCompare('第05集', '第5集'), 0);
  });
}
