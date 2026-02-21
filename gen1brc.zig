const std = @import("std");

pub fn main() !void {
    var rng = std.rand.DefaultPrng.init(0);
    const random = rng.random();
    const cities = [_][]const u8{ "Tokyo", "Jakarta", "Delhi", "Guangzhou", "Mumbai", "Manila", "Shanghai", "Sao Paulo", "Seoul", "Mexico City", "Cairo", "New York", "Dhaka", "Beijing", "Kolkata", "Bangkok", "Shenzhen", "Moscow", "Buenos Aires", "Lagos", "Istanbul", "Karachi", "Bangalore", "Ho Chi Minh City", "Osaka", "Chengdu", "Tehran", "Kinshasa", "Rio de Janeiro", "Chennai", "Xi'an", "Lahore", "Chongqing", "Los Angeles", "Baoding", "London", "Paris", "Linyi", "Dongguan", "Hyderabad", "Tianjin", "Lima", "Wuhan", "Nanyang", "Hangzhou", "Foshan", "Nagoya", "Taipei", "Tongshan", "Luanda", "Zhoukou", "Ganzhou", "Kuala Lumpur", "Heze", "Quanzhou", "Chicago", "Nanjing", "Jining", "Hanoi", "Pune", "Fuyang", "Ahmedabad", "Johannesburg", "Bogota", "Dar es Salaam", "Shenyang", "Khartoum", "Shangqiu", "Cangzhou", "Hong Kong", "Shaoyang", "Zhanjiang", "Yancheng", "Hengyang", "Riyadh", "Zhumadian", "Santiago", "Xingtai", "Chattogram", "Bijie", "Shangrao", "Zunyi", "Surat", "Surabaya", "Huanggang", "Maoming", "Nanchong", "Xinyang", "Madrid", "Baghdad", "Qujing", "Jieyang", "Singapore", "Prayagraj", "Liaocheng", "Dalian", "Yulin", "Changde", "Qingdao" };
    const file_path = "1brc.txt";
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    var bw = std.io.bufferedWriter(file.writer());
    const w = bw.writer();

    for (0..1_000_000_000) |_| {
        const random_index = random.uintLessThan(usize, cities.len);
        const temp = random.floatNorm(f32) * 10.0;
        const city = cities[random_index];
        try std.fmt.format(w, "{s};{d:.1}\n", .{ city, temp });
    }
    try bw.flush();
}
